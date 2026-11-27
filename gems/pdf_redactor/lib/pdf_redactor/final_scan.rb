# frozen_string_literal: true

module PDFRedactor
  ##
  # Reads a whole PDF for the rules, as it would be published
  # (Disclosures::RuleCheck): every string, the trailer's too, every stream
  # that can hold text, attached files, and the text pdftotext gives it with
  # hidden text shown. A rule that matches, perhaps where Redactor never
  # reads (an XFA form, JavaScript, a signature, a pattern), raises Matched.
  # A part it can't read raises Error: it fails closed.
  #
  # Every other stream is read as text three ways: UTF-8, Latin-1 (which is
  # PDFDocEncoding for letters) and UTF-16 by its byte order mark. A stream
  # that isn't text is read for the literal rules alone (censor rules, names),
  # not for patterns such as an email address, which random bytes can match.
  # A stream that is itself a file nothing here reads (a zip such as an ODF
  # or OOXML document, an OLE file, a PDF other than an attached one,
  # Illustrator's compressed data) raises. An attached PDF is read as a file
  # of its own, to the depth Redactor masks; an attached file that is
  # neither a PDF nor text raises.
  #
  # Not read:
  # - pictures and font programs: their bytes aren't text, so a pattern such
  #   as an email address could match them by chance and stop any file.
  #   A stream counts as one only when it is reached as nothing else (a
  #   picture from /XObject resources, /SMask, /Mask, /Thumb, /Image or a
  #   structure's /Obj; a font program from a FontDescriptor's /FontFile*).
  #   A picture's text is still read: JPEG 2000's XML and UUID (XMP) boxes,
  #   and a JPEG's APPn and comment segments wherever they are, with
  #   anything after its end;
  # - names;
  # - the bytes of the text that pages in the page tree show (Tj, TJ, ' and
  #   "): a font can draw codes that spell a rule as other letters, so they
  #   would stop a file for nothing. That text is read instead as poppler
  #   reads it through the fonts, as readers and copy-paste do (#check_text!).
  #   Every other content stream (forms, patterns, Type 3 glyphs, templates)
  #   is read by its bytes.
  class FinalScan
    FONT_FILES = %w[FontFile FontFile2 FontFile3].freeze
    SHOW = %w[Tj TJ ' "].freeze
    # Files that can start anywhere in a stream. gzip's is long enough, with
    # its flags, OS and compression bytes, that random data won't make it.
    # :archive is compressed, so masking's byte pass can't reach inside it
    # either: AlaveteliTextMasker serves one as it came, marked.
    CONTAINERS = [
      [/PK\x03\x04/n, 'a zip file, such as an ODF or OOXML document', :archive],
      [/\xD0\xCF\x11\xE0\xA1\xB1\x1A\xE1/n,
       'an OLE file, such as a Word or Outlook file', :ole],
      [/7z\xBC\xAF\x27\x1C/n, 'a 7-Zip file', :archive],
      [/Rar!\x1A\x07/n, 'a RAR file', :archive],
      [/\x1F\x8B\x08[\x00-\x1F].{4}[\x00\x02\x04][\x00-\x0D\xFF]/mn,
       'gzip data', :archive]
    ].freeze
    ILLUSTRATOR = /%AI\d+_CompressedData/n
    PDF_HEADER = /%PDF-\d+\.\d+/n
    PDF_WS = '(?:[\x00\s]|%[^\r\n]*[\r\n])+'
    PDF_OBJECT = /\b\d+#{PDF_WS}\d+#{PDF_WS}obj(?=[\x00\s<\[(\/%]|\z)/n
    # Characters a reader doesn't see: soft hyphens and zero-width ones.
    UNSEEN = "\u00AD\u200B\u200C\u200D\u2060\uFEFF"
    # What can come between a word's letters and leave it readable.
    BETWEEN = '[\s\-\u2010\u2011]*'
    # A page box that holds text drawn far off the page.
    # (Far bigger, such as 1e30, and poppler returns no text at all.)
    BIG_BOX = [-1e9, -1e9, 1e9, 1e9].map(&:to_i).freeze
    # Keys a picture is reached by as a picture, besides /XObject resources.
    PICTURE_KEYS = %w[SMask Mask Thumb Image Obj].freeze
    # Pictures whose text is read (#picture_parts).
    PICTURE_TEXT_FILTERS = %w[DCTDecode DCT JPXDecode].freeze

    # depth: how deep an attached PDF this is, as Redactor counts it.
    def self.check!(pdf, rules, depth: 0)
      return if rules.empty?
      if depth.zero? && PDFRedactor.isolated?
        return PDFRedactor.backend.final_scan(pdf, rules)
      end

      qdf, = PDFRedactor.qpdf(pdf, '--qdf', '--object-streams=disable',
                              '--decode-level=none')
      scan = new(QdfDoc.new(qdf), rules, depth)
      scan.check!
      scan.check_text!(pdf)
    end

    def initialize(doc, rules, depth = 0)
      @doc = doc
      @rules = rules
      @depth = depth
      @attached = doc.attached_streams
    end

    def check!
      skip, contents = sort_streams
      pages = page_contents
      strings(@doc.trailer).each { |text| check(text, 'the trailer') }
      @doc.offsets.each_key do |n|
        next unless (o = @doc.object(n))

        strings(o[:value]).each { |text| check(text, "object #{n}") }
        next unless o[:stream]
        next check_picture(n) if skip.include?(n)

        kind = if pages.include?(n) then :page
               elsif contents.include?(n) then :content
               end
        check_stream(n, kind)
      end
    end

    # The file's text as pdftotext gives it, decoded through the fonts and
    # their ToUnicode maps by poppler, not by Redactor: of the file itself,
    # and of a copy with what pdftotext would leave out shown (#revealed).
    # The copy has to give at least as much text, in case poppler reads it
    # oddly. If pdftotext is missing or fails, that raises too, so the file
    # is withheld.
    def check_text!(pdf)
      rules = @rules + loose_rules
      shown, all = [pdf, revealed].map do |file|
        pdftotext(file).tap { check(_1, 'the text pdftotext reads', rules) }
      end
      return if all.gsub(/\s+/, '').length >= shown.gsub(/\s+/, '').length

      raise Error, 'pdftotext read less text from the copy that shows ' \
                   'hidden text than from the file (final scan)'
    end

    private

    def pdftotext(pdf)
      runner = PDFRedactor.backend
      text = runner.job(input: pdf, input_name: 'masked.pdf') do |job|
        job.run('pdftotext', '-q', '-enc', 'UTF-8', job.input, '-').stdout
      end
      text.dup.force_encoding('UTF-8').scrub.unicode_normalize(:nfkc).
        delete(UNSEEN)
    end

    # Each literal rule again, with its letters allowed apart: "J a n e" or
    # "Doe-little" read as the name. Only on the text a reader gets, where a
    # near match is still the name on the page.
    def loose_rules
      @rules.filter_map do |rule|
        next unless rule.literal && rule.text

        letters = rule.text.unicode_normalize(:nfkc).gsub(/\s+/, '').chars
        next if letters.size < 2

        body = letters.map { |c| Regexp.escape(c) }.join(BETWEEN)
        re = Regexp.new("(?<![[:alnum:]])#{body}(?![[:alnum:]])",
                        rule.re.options & Regexp::IGNORECASE)
        Rule.new(re, true)
      end
    end

    # The file with every optional content layer on (no /OCProperties), no
    # annotation hidden by its flags (no /F), and every page box big enough
    # for text drawn off the page (no /CropBox), for pdftotext only. qpdf
    # gives a page with no /MediaBox a Letter one, so every page has one.
    def revealed
      edits = @doc.offsets.each_key.filter_map do |n|
        next unless (o = @doc.object(n))

        value = reveal(o[:value])
        [*o[:dict], Serialize.dump(value).b] unless value == o[:value]
      end
      @doc.rewrite(edits)
    end

    def reveal(value)
      case value
      when Array then value.map { |v| reveal(v) }
      when Hash
        out = value.except('OCProperties', 'CropBox').
              transform_values { |v| reveal(v) }
        out['MediaBox'] = BIG_BOX if value.key?('MediaBox')
        # An annotation's flags, not a file specification's /F.
        out.delete('F') if value.key?('Rect') && value.key?('Subtype')
        out
      else value
      end
    end

    # [pictures and font programs, content streams], by object number.
    def sort_streams
      contents = Set.new
      pictures, fonts, elsewhere = reached
      @doc.offsets.each_key do |n|
        next unless (o = @doc.object(n))

        PDFRedactor.each_dict(o[:value]) do |dict|
          if @doc.name(dict['Type']) == 'Page'
            contents.merge(stream_refs(dict['Contents']).map(&:num))
          end
          procs = @doc.resolve(dict['CharProcs'])
          contents.merge(procs.values.grep(Ref).map(&:num)) if procs.is_a?(Hash)
        end
        v = o[:value]
        next unless o[:stream] && v.is_a?(Hash)

        form = @doc.name(v['Subtype']) == 'Form'
        contents << n if form || @doc.resolve(v['PatternType']) == 1
      end
      [(pictures | fonts) - elsewhere, contents]
    end

    # [pictures, font programs, streams reached any other way], by how each
    # reference to them is reached.
    def reached
      xobjects = Set.new
      @doc.offsets.each_key do |n|
        each_ref(@doc.object(n)&.dig(:value)) do |ref, key|
          xobjects << ref.num if key == 'XObject'
        end
      end
      pictures = Set.new
      fonts = Set.new
      elsewhere = Set.new
      each_ref(@doc.trailer) { |ref, *| elsewhere << ref.num }
      @doc.offsets.each_key do |n|
        next unless (o = @doc.object(n))

        v = o[:value]
        if o[:stream] && v.is_a?(Hash) && @doc.name(v['Subtype']) == 'Image'
          pictures << n
        end
        each_ref(v, xobjects: xobjects.include?(n)) do |ref, key, owner, x|
          if FONT_FILES.include?(key) &&
             @doc.name(owner['Type']) == 'FontDescriptor'
            fonts << ref.num
          elsif !x && !PICTURE_KEYS.include?(key)
            elsewhere << ref.num
          end
        end
      end
      [pictures, fonts, elsewhere]
    end

    # Each reference in a value, with the key it is under, the dictionary
    # that holds it, and whether that dictionary is /XObject resources.
    def each_ref(value, key = nil, owner = nil, xobjects: false, &block)
      case value
      when Ref then yield value, key, owner, xobjects
      when Array
        value.each { |v| each_ref(v, key, owner, xobjects: xobjects, &block) }
      when Hash
        value.each do |k, v|
          inner = v.is_a?(Hash) ? k == 'XObject' : xobjects
          each_ref(v, k, value, xobjects: inner, &block)
        end
      end
    end

    # The text a picture carries: only a JPEG's or JPEG 2000's is read, so
    # any other picture isn't decoded (a PNG predictor, for one, isn't
    # decoded here, and needn't be).
    def check_picture(n)
      dict = @doc.object(n)[:value]
      filters = PDFRedactor.list(@doc.resolve(dict['Filter'])).
                map { |f| @doc.name(f) }
      return unless filters.intersect?(PICTURE_TEXT_FILTERS)

      data, rest = @doc.decoded(n)
      check_parts(picture_parts(data, rest), "object #{n}")
    rescue NeedsFullDecode => e
      raise Error, "the final scan could not decode object #{n} (#{e.message})"
    end

    def picture_parts(data, filters)
      case filters.first
      when 'JPXDecode' then jp2_boxes(data)
      when 'DCTDecode', 'DCT' then jpeg_segments(data)
      else []
      end
    end

    def check_parts(parts, where)
      parts.each do |part|
        check_container(part, where)
        check_bytes(part, where)
      end
    end

    # JPEG 2000's top-level XML and UUID boxes, which hold XML and XMP.
    def jp2_boxes(data)
      out = []
      pos = 0
      while pos + 8 <= data.bytesize
        size, type = data.byteslice(pos, 8).unpack('Na4')
        head = 8
        if size == 1
          break if pos + 16 > data.bytesize

          size = data.byteslice(pos + 8, 8).unpack1('Q>')
          head = 16
        elsif size.zero?
          size = data.bytesize - pos
        end
        break if size < head

        avail = data.bytesize - (pos + head)
        len = size - head
        len = avail if len > avail
        if ['xml ', 'uuid'].include?(type)
          out << data.byteslice(pos + head, len)
        end
        break if size > data.bytesize - pos

        pos += size
      end
      out
    end

    # A JPEG's APPn and comment segments, before its first scan and after,
    # and whatever follows its end.
    def jpeg_segments(data)
      out = []
      pos = 2
      while (pos = data.index("\xFF".b, pos)) && pos + 1 < data.bytesize
        marker = data.getbyte(pos + 1)
        if marker == 0xD9
          tail = data.byteslice((pos + 2)..)
          out << tail unless tail.empty?
          break
        end
        # Stuffing, fill and restart markers carry no length.
        if marker.zero? || marker == 0xFF || marker == 0x01 ||
           (0xD0..0xD7).cover?(marker)
          pos += marker == 0xFF ? 1 : 2
          next
        end
        size = data.byteslice(pos + 2, 2).to_s.unpack1('n').to_i
        break if size < 2

        if (0xE0..0xEF).cover?(marker) || marker == 0xFE
          out << data.byteslice(pos + 4, size - 2).to_s
        end
        pos += 2 + size
      end
      out
    end

    # The content streams of the pages in the page tree, which Redactor reads.
    def page_contents
      @doc.pages.flat_map { |page, *| stream_refs(page['Contents']) }.
        to_set(&:num)
    end

    def stream_refs(value)
      resolved = @doc.resolve(value)
      (resolved.is_a?(Array) ? resolved : [value]).grep(Ref)
    end

    # kind: :page for a page's content stream, :content for any other.
    def check_stream(n, kind)
      data, rest = @doc.decoded(n)
      where = "object #{n}"
      return check_attached(data, where) if @attached.include?(n)
      # Left encoded as a picture, though nothing reaches it as one: its
      # bytes are read as they are.
      return check_parts([data, *picture_parts(data, rest)], where) if rest.any?
      return check_content(data, where, shown: false) if kind == :page

      check_container(data, where)
      check_bytes(data, where)
      check_content(data, where) if kind == :content
    rescue NeedsFullDecode => e
      raise Error, "the final scan could not decode object #{n} (#{e.message})"
    end

    # An attached PDF is read as a file of its own, to the depth Redactor
    # masks, and attached text by its bytes. Any other attached file can't be
    # read here, nor can an attached PDF deeper than that, so they raise.
    def check_attached(data, where)
      if data.start_with?('%PDF') && @depth < 3
        return self.class.check!(data, @rules, depth: @depth + 1)
      end
      unless text?(data) && !pdf_header?(data)
        raise Error, "#{where} is an attached file that can't be read " \
                     '(final scan)'
      end

      check_container(data, where)
      check_bytes(data, where)
    end

    # The strings in each operator, a TJ array's joined up too. Unless shown,
    # not those that operators show.
    def check_content(data, where, shown: true)
      Lexer.each_op(data) do |op, args, start, stop|
        if op == 'BI'
          next check_inline_image(data.byteslice(start...stop), where)
        end
        next if !shown && SHOW.include?(op)

        texts = strings(args)
        if op == 'TJ' && args[0].is_a?(Array)
          joined = args[0].grep(PStr).map(&:bytes).join
          texts << Redactor.decode_text_string(joined)
        end
        texts.each { |text| check(text, where) }
      end
    end

    def strings(value, out = [])
      case value
      when PStr then out << Redactor.decode_text_string(value.bytes)
      when Array then value.each { |v| strings(v, out) }
      when Hash then value.each_value { |v| strings(v, out) }
      end
      out
    end

    # An inline JPEG's APPn and comment segments, which Redactor doesn't
    # censor.
    def check_inline_image(bytes, where)
      return unless (at = bytes.index("\xFF\xD8".b))

      check_parts(jpeg_segments(bytes.byteslice(at..)), where)
    end

    def check_container(data, where)
      found = 'a PDF' if pdf_header?(data)
      found ||= CONTAINERS.find { |pattern, *| data.match?(pattern) }&.[](1)
      if data.byteslice(0, 1024).match?(ILLUSTRATOR)
        found ||= "Illustrator's compressed data"
      end
      return unless found

      raise Error, "#{where} holds #{found}, which is not read (final scan)"
    end

    # Starts with %PDF, or has a %PDF-x.y header within the first 1,024 bytes
    # followed by a PDF indirect object (distinguishing an actual embedded PDF
    # from plain text that merely mentions "%PDF-1.7").
    def pdf_header?(data)
      return true if data.start_with?('%PDF')

      raw = data.encoding == Encoding::BINARY ? data : data.b
      match = PDF_HEADER.match(raw.byteslice(0, 1032).to_s)
      return false unless match && match.begin(0) < 1024

      raw.match?(PDF_OBJECT, match.end(0))
    end

    def check_bytes(data, where)
      binary = !text?(data)
      rules = binary ? @rules.select(&:literal) : @rules
      texts = [data.dup.force_encoding('UTF-8').scrub,
               data.dup.force_encoding('ISO-8859-1').encode('UTF-8')]
      texts << utf16(data) if utf16?(data)
      # UTF-16 with no byte order mark, as Exif's XPAuthor is.
      if binary
        texts << data.delete("\x00".b).force_encoding('ISO-8859-1').
                 encode('UTF-8')
      end
      texts.each { |text| check(text, where, rules) }
    end

    # UTF-8, UTF-16 by its byte order mark, or mostly printable ASCII.
    def text?(data)
      return true if Redactor.text?(data) || utf16?(data)

      sample = data.byteslice(0, 4096)
      sample.count("\t\n\r\x20-\x7E") >= sample.bytesize * 0.9
    end

    def utf16?(data) = data.start_with?("\xFE\xFF".b, "\xFF\xFE".b)

    def utf16(data)
      order = data.start_with?("\xFE\xFF".b) ? 'UTF-16BE' : 'UTF-16LE'
      data.byteslice(2..).force_encoding(order).
        encode('UTF-8', invalid: :replace, undef: :replace)
    end

    # The message names the object, never the text.
    def check(text, where, rules = @rules)
      candidates = [text]
      unless text.ascii_only?
        norm = text.unicode_normalize(:nfkc).delete(UNSEEN)
        candidates << norm unless norm == text
      end
      matched = candidates.any? do |candidate|
        rules.any? { |rule| candidate.match?(rule.re) }
      end
      return unless matched

      raise Matched, "a rule still matches in #{where} after masking " \
                     '(final scan)'
    end
  end
end
