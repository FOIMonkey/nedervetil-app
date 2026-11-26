# frozen_string_literal: true

require 'office_package/archive'

module OfficePackage
  ##
  # The Open Packaging Conventions over an Archive: parts by name (ignoring
  # case, as OPC does), content types, and relationships. XML parts are
  # parsed strictly, without the network, and refused if they declare a
  # DOCTYPE. Changes are kept until to_bytes: a parsed part changed in place
  # is marked with changed!, and removing a part also removes the
  # relationships that point at it, its own relationships part and its
  # content-type override. References to a removed relationship left in the
  # part that held it (an r:id) are pruned when the package is written.
  class Package
    Relationship = Struct.new(:id, :type, :target, :external, :source,
                              :node, keyword_init: true) do
      # The type's last segment: "comments" for both the Transitional and
      # Strict comments types.
      def kind
        type.to_s[%r{[^/]+\z}].to_s
      end
    end

    # Containers left empty when what they held is pruned.
    PRUNABLE = %w[extLst ext pivotCaches].freeze
    XML_PART = /\.(?:xml|rels|vml)\z/i

    attr_reader :archive

    def initialize(bytes)
      unless OfficePackage.package?(bytes)
        if bytes.to_s.b.start_with?(COMPOUND_FILE_MAGIC)
          raise NotPackage, 'a compound file, such as an encrypted or ' \
                            'older Office file'
        end
        raise NotPackage, 'not a zip'
      end

      @archive = Archive.new(bytes)
      @index = archive.entries.reject(&:directory?).
               to_h { |entry| [entry.name.downcase, entry] }
      @data = {}
      @docs = {}
      @dirty = Set.new
      @removed = Set.new
      @dangling = Hash.new { |hash, key| hash[key] = Set.new }
    end

    def names
      archive.entries.filter_map do |entry|
        entry.name if @index.key?(entry.name.downcase) &&
                      !@removed.include?(entry.name.downcase)
      end
    end

    def include?(name)
      key = name.to_s.downcase
      @index.key?(key) && !@removed.include?(key)
    end

    # The part's name as stored, or nil.
    def lookup(name)
      [name.to_s, unescape(name.to_s)].each do |candidate|
        return @index[candidate.downcase].name if include?(candidate)
      end
      nil
    end

    def size(name)
      entry!(name).uncompressed_size
    end

    def read(name)
      key = entry!(name).name.downcase
      return serialize(@docs[key]) if @dirty.include?(key) && @docs.key?(key)
      return @data[key] if @data.key?(key)

      archive.data(@index.fetch(key))
    end

    def xml(name)
      key = entry!(name).name.downcase
      @docs[key] ||= parse(read(name))
    end

    def xml_part?(name)
      name.to_s.match?(XML_PART)
    end

    def changed!(name)
      @dirty << entry!(name).name.downcase
    end

    def write(name, bytes)
      key = entry!(name).name.downcase
      @docs.delete(key)
      @data[key] = bytes.b
      @dirty << key
    end

    def changed?
      @dirty.any? || @removed.any? || archive.leftovers?
    end

    # What the zip holds outside its parts that could be data: gaps,
    # comments and extra fields of unknown kinds. (Every extra field is
    # dropped when the package is written: Archive#leftovers?)
    def leftover_bytes
      archive.leftover_bytes + archive.comment_bytes + archive.extra_data_bytes
    end

    # Archive#unlisted: what's in the zip outside its parts.
    def unlisted
      archive.unlisted
    end

    # The part's stored name, or nil if there was no such part.
    def remove(name)
      name = lookup(name) or return
      key = name.downcase
      @removed << key
      @dirty.delete(key)
      @docs.delete(key)
      rels_parts.each do |rels, source|
        doc = xml(rels)
        doc.root&.element_children&.each do |node|
          next unless node.name == 'Relationship'
          next if external?(node)

          target = resolve(source, node['Target'])
          next unless [target, unescape(target)].any? do |path|
            path.casecmp?(name) || path.casecmp?(unescape(name))
          end

          @dangling[source] << node['Id'].to_s
          node.remove
          changed!(rels)
        end
      end
      own = rels_name(name)
      remove(own) if include?(own)
      remove_override(name)
      name
    end

    # Removes one relationship (an external one, say), leaving its target.
    def drop_relationship(rel)
      rel.node.remove
      changed!(rels_name(rel.source))
      @dangling[rel.source] << rel.id
    end

    # Relationships held by source ('' for the package's own).
    def relationships(source)
      rels = rels_name(source)
      return [] unless include?(rels)

      xml(rels).root&.element_children.to_a.filter_map do |node|
        next unless node.name == 'Relationship'

        external = external?(node)
        target = node['Target'].to_s
        unless external
          path = resolve(source, target)
          target = lookup(path) || path
        end
        Relationship.new(id: node['Id'].to_s, type: node['Type'].to_s,
                         target: target, external: external, source: source,
                         node: node)
      end
    end

    def related(source, *kinds)
      relationships(source).select do |rel|
        !rel.external && kinds.include?(rel.kind) && include?(rel.target)
      end
    end

    def rels_name(part)
      return PACKAGE_RELS if part.to_s.empty?

      dir, base = File.split(part)
      dir == '.' ? "_rels/#{base}.rels" : "#{dir}/_rels/#{base}.rels"
    end

    def content_type(name)
      overrides, defaults = content_types
      name = name.to_s
      ext = if name.include?("\0")
              ''
            else
              File.extname(name).delete_prefix('.').downcase
            end
      overrides[name.downcase] || overrides[unescape(name).downcase] ||
        defaults[ext]
    end

    def main_part
      rel = relationships('').find do |item|
        item.kind == 'officeDocument' && !item.external
      end
      rel && lookup(rel.target)
    end

    def kind
      case content_type(main_part.to_s).to_s
      when /wordprocessingml\.(?:document|template)|ms-word\./
        :document
      when /spreadsheetml\.(?:sheet|template)|ms-excel\./
        :spreadsheet
      when /presentationml\.(?:presentation|slideshow|template)|ms-powerpoint\./
        :presentation
      end
    end

    # Parts no relationship reaches from the package: no reader opens them.
    def unreachable_parts
      seen = Set.new([CONTENT_TYPES.downcase])
      queue = ['']
      until queue.empty?
        source = queue.shift
        rels = rels_name(source)
        next unless include?(rels)

        seen << rels.downcase
        relationships(source).each do |rel|
          next if rel.external || !include?(rel.target)
          next if seen.include?(rel.target.downcase)

          seen << rel.target.downcase
          queue << rel.target
        end
      end
      names.reject { |name| seen.include?(name.downcase) }
    end

    def to_bytes
      prune_references!
      return archive.bytes unless changed?

      items = archive.entries.filter_map do |entry|
        key = entry.name.downcase
        next if @removed.include?(key)

        data = if @dirty.include?(key)
                 @docs.key?(key) ? serialize(@docs[key]) : @data[key]
               end
        [entry, data]
      end
      Writer.write(archive, items)
    end

    private

    def entry!(name)
      found = lookup(name) or raise Error, 'no such part'
      @index.fetch(found.downcase)
    end

    def parse(data)
      if data.bytesize > OfficePackage.limits[:xml_part]
        raise Refused, 'a part over the size limit'
      end
      raise Refused, 'a part that declares a DOCTYPE' if
        OfficePackage.doctype?(data)

      doc = Nokogiri::XML(data) { |config| config.strict.nonet }
      raise Refused, 'a part that declares a DOCTYPE' if doc.internal_subset

      doc
    rescue Nokogiri::XML::SyntaxError
      raise Refused, 'a part that is not well-formed XML'
    end

    def serialize(doc)
      doc.to_xml(encoding: doc.encoding || 'UTF-8',
                 save_with: Nokogiri::XML::Node::SaveOptions::AS_XML).b
    end

    def external?(node)
      node['TargetMode'].to_s.casecmp?('External')
    end

    # Relationship parts and the part each describes ('' for the package).
    def rels_parts
      names.filter_map do |name|
        dir, base = File.split(name)
        next unless base.downcase.end_with?('.rels') &&
                    File.basename(dir).casecmp?('_rels')

        parent = File.dirname(dir)
        base = base[0...-5]
        [name, parent == '.' ? base : "#{parent}/#{base}"]
      end
    end

    def resolve(source, target)
      target = target.to_s.split('#').first.to_s
      path = if target.start_with?('/')
               target
             else
               File.join(File.dirname(source.to_s), target)
             end
      segments = []
      path.split('/').each do |segment|
        case segment
        when '', '.' then next
        when '..' then segments.pop
        else segments << segment
        end
      end
      segments.join('/')
    end

    def unescape(name)
      text = name.gsub(/%[0-9A-Fa-f]{2}/) { |code| code[1..].hex.chr }.
             force_encoding('UTF-8')
      text.valid_encoding? && !text.include?("\0") ? text : name
    end

    def part_name?(declared, name)
      declared = declared.to_s.delete_prefix('/')
      declared.casecmp?(name) || unescape(declared).casecmp?(unescape(name))
    end

    def content_types
      @content_types ||= begin
        overrides = {}
        defaults = {}
        if include?(CONTENT_TYPES)
          xml(CONTENT_TYPES).root&.element_children.to_a.each do |node|
            case node.name
            when 'Override'
              part = node['PartName'].to_s.delete_prefix('/')
              overrides[part.downcase] ||= node['ContentType']
              overrides[unescape(part).downcase] ||= node['ContentType']
            when 'Default'
              defaults[node['Extension'].to_s.downcase] ||= node['ContentType']
            end
          end
        end
        [overrides, defaults]
      end
    end

    def remove_override(name)
      return unless include?(CONTENT_TYPES)

      doc = xml(CONTENT_TYPES)
      doc.root&.element_children.to_a.each do |node|
        next unless node.name == 'Override' &&
                    part_name?(node['PartName'], name)

        node.remove
        changed!(CONTENT_TYPES)
        @content_types = nil
      end
    end

    def prune_references!
      @dangling.each do |source, ids|
        next if source.empty? || !include?(source) || !xml_part?(source)

        doc = xml(source)
        hits = doc.xpath('//@*').select do |attribute|
          RELATIONSHIPS_NS.include?(attribute.namespace&.href) &&
            ids.include?(attribute.value)
        end
        next if hits.empty?

        hits.each do |attribute|
          element = attribute.parent
          holder = element.parent&.name == 'ext' ? element.parent : element
          container = holder.parent
          holder.remove
          prune_empty(container)
        end
        changed!(source)
      end
      @dangling.clear
    end

    def prune_empty(node)
      while node.is_a?(Nokogiri::XML::Element) &&
            PRUNABLE.include?(node.name) && node.element_children.empty?
        parent = node.parent
        node.remove
        node = parent
      end
    end
  end
end
