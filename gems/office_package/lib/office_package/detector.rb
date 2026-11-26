# frozen_string_literal: true

module OfficePackage
  # Checks whether a matcher hits anywhere in an Office or OLE file: XML
  # nodes, attributes and reconstructed blocks (runs, rows, accepted and
  # original tracked text), binary/leftover strings, OLE streams, part names
  # and nested files up to MAX_DEPTH. Unreadable items (media, fonts,
  # encrypted/deeply nested files, compressed VBA) go in not_checked.
  class Detector
    Hit = Struct.new(:part, :where, keyword_init: true)
    Result = Struct.new(:hits, :not_checked, keyword_init: true) do
      def match?
        hits.any?
      end
    end
    Block = Struct.new(:accepted, :original, keyword_init: true)

    MAX_DEPTH = 2
    SEPARATOR = "\u0000"
    # Attributes that only tie the file together: relationship and revision
    # ids, paragraph ids and cell references. Kept short on purpose.
    SKIPPED = /\A(?:id|embed|link|pict|r|ref|sqref|paraId|textId|rsid\w*)\z/
    UNREAD = /\.(?:png|jpe?g|gif|bmp|tiff?|emf|wmf|svg|ico|ttf|odttf|otf|
               fntdata|wav|mp3|mp4|m4a|wma|wmv|avi|mov)\z/xi
    BLOCKS = %w[p si is row tr].freeze
    CELLS = %w[c tc].freeze
    DELETED = %w[del moveFrom].freeze
    INSERTED = %w[ins moveTo].freeze
    TEXT_NODES = [Nokogiri::XML::Reader::TYPE_TEXT,
                  Nokogiri::XML::Reader::TYPE_CDATA,
                  Nokogiri::XML::Reader::TYPE_SIGNIFICANT_WHITESPACE].freeze
    # Never shown, but in the file all the same.
    UNSHOWN_NODES = [Nokogiri::XML::Reader::TYPE_COMMENT,
                     Nokogiri::XML::Reader::TYPE_PROCESSING_INSTRUCTION].freeze
    READER_OPTIONS = Nokogiri::XML::ParseOptions::NONET |
                     Nokogiri::XML::ParseOptions::BIG_LINES
    # Printable runs: ASCII and UTF-8 sequences, and UTF-16LE in the Latin
    # range.
    NARROW = /(?:[\t\x20-\x7E]|[\xC2-\xF4][\x80-\xBF]{1,3}){4,}/n
    WIDE = /(?:[\t\x20-\x7E\xA0-\xFF]\x00){4,}/n

    def self.call(bytes, matcher)
      new(matcher, 0).scan(bytes, 'file')
    end

    def initialize(matcher, depth)
      @matcher = matcher
      @depth = depth
      @hits = []
      @not_checked = []
    end

    def scan(bytes, label)
      bytes = bytes.to_s.b
      if bytes.start_with?(COMPOUND_FILE_MAGIC)
        compound(bytes, label)
      elsif OfficePackage.package?(bytes)
        package(OfficePackage.read(bytes))
      else
        check(strings(bytes), label, 'strings')
      end
      Result.new(hits: @hits, not_checked: @not_checked)
    end

    private

    def check(text, part, where)
      text = text.to_s.dup.force_encoding('UTF-8').scrub
      return if text.empty?

      @hits << Hit.new(part: part, where: where) if @matcher.call(text)
    end

    def package(package)
      check(package.names.join(SEPARATOR), 'part names', 'names')
      check(package.unlisted.map { |data| strings(data) }.join(SEPARATOR),
            'outside the parts', 'strings')
      shared = shared_strings(package)
      package.names.each do |name|
        if package.xml_part?(name)
          xml(package.read(name), name, shared)
        else
          binary(package.read(name), name)
        end
      end
    end

    def binary(data, name)
      if OfficePackage.package?(data) || data.b.start_with?(COMPOUND_FILE_MAGIC)
        nested(data, name)
      elsif name.match?(UNREAD)
        @not_checked << name
      else
        check(strings(data), name, 'strings')
      end
    end

    def nested(data, name)
      if @depth >= MAX_DEPTH
        @not_checked << name
        return
      end

      result = Detector.new(@matcher, @depth + 1).scan(data, name)
      result.hits.each do |hit|
        @hits << Hit.new(part: within(name, hit.part), where: hit.where)
      end
      @not_checked.concat(result.not_checked.map { |part| within(name, part) })
    end

    # A compound file's labels already start with its name; a package's
    # parts don't.
    def within(name, part)
      part == name || part.start_with?("#{name}/") ? part : "#{name}/#{part}"
    end

    def compound(data, label)
      file = CompoundFile.new(data)
      if file.encrypted?
        @not_checked << label
        return
      end

      file.streams.each do |path, stream|
        check(path, label, 'stream names')
        if OfficePackage.package?(stream)
          nested(stream, "#{label}/#{path}")
        else
          check(strings(stream), "#{label}/#{path}", 'strings')
        end
        @not_checked << "#{label}/#{path}" if path.match?(%r{\AVBA/}i)
      end
      # Free sectors keep what was deleted; read the raw file as well.
      check(strings(data), label, 'free space')
    rescue Refused, NotPackage
      check(strings(data), label, 'strings')
    end

    def shared_strings(package)
      name = package.names.find do |part|
        package.content_type(part).to_s.include?('sharedStrings')
      end
      return [] unless name

      package.xml(name).xpath('//*[local-name()="si"]').map do |item|
        item.xpath('./*[local-name()="t"] | ' \
                   './*[local-name()="r"]/*[local-name()="t"]').
          map(&:text).join
      end
    end

    # Every node and every block, through the streaming reader, so a large
    # part never becomes one document in memory.
    def xml(data, name, shared)
      if data.bytesize > OfficePackage.limits[:xml_part]
        raise Refused, 'a part over the size limit'
      end
      raise Refused, 'a part that declares a DOCTYPE' if
        data.b.include?('<!DOCTYPE'.b)

      @nodes = +''
      @blocks = []
      @open = []
      @deleting = 0
      @inserting = 0
      @shared_cell = false
      @value = false
      Nokogiri::XML::Reader(data, nil, nil, READER_OPTIONS).each do |node|
        read(node, shared)
      end
      check(@nodes, name, 'text')
      check(@blocks.map { |block| block.gsub(/[[:space:]]+/, ' ') }.
            join(SEPARATOR), name, 'blocks')
    rescue Nokogiri::XML::SyntaxError
      raise Refused, 'a part that is not well-formed XML'
    end

    def read(node, shared)
      case node.node_type
      when Nokogiri::XML::Reader::TYPE_ELEMENT then start(node)
      when Nokogiri::XML::Reader::TYPE_END_ELEMENT then finish(node.local_name)
      when *TEXT_NODES
        text = node.value.to_s
        @nodes << text << SEPARATOR
        text = shared[text.to_i].to_s if @value && @shared_cell
        add(text)
      when *UNSHOWN_NODES
        @nodes << node.name.to_s << SEPARATOR << node.value.to_s << SEPARATOR
      end
    end

    def start(node)
      node.attribute_hash.each do |qualified, value|
        next if qualified.split(':').last.match?(SKIPPED)

        @nodes << value.to_s << SEPARATOR
      end
      name = node.local_name
      case name
      when 'tab' then add("\t")
      when 'br', 'cr' then add("\n")
      when 'c' then @shared_cell = node.attribute('t') == 's'
      when 'v' then @value = true
      end
      @deleting += 1 if DELETED.include?(name)
      @inserting += 1 if INSERTED.include?(name)
      @open << Block.new(accepted: +'', original: +'') if BLOCKS.include?(name)
      finish(name) if node.empty_element?
    end

    def finish(name)
      @deleting -= 1 if DELETED.include?(name) && @deleting.positive?
      @inserting -= 1 if INSERTED.include?(name) && @inserting.positive?
      @value = false if name == 'v'
      add("\t") if CELLS.include?(name)
      close if BLOCKS.include?(name)
    end

    def add(text)
      @open.each do |block|
        block.accepted << text unless @deleting.positive?
        block.original << text unless @inserting.positive?
      end
    end

    def close
      block = @open.pop or return
      @blocks << block.accepted << block.original
      add("\n")
    end

    def strings(data)
      data = data.to_s.b
      narrow = data.scan(NARROW).map do |run|
        run.force_encoding('UTF-8').scrub
      end
      wide = data.scan(WIDE).map do |run|
        run.force_encoding('UTF-16LE').encode('UTF-8', invalid: :replace,
                                                       undef: :replace)
      end
      (narrow + wide).join(SEPARATOR)
    end
  end
end
