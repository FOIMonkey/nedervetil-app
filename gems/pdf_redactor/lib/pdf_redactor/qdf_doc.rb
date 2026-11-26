# frozen_string_literal: true

require 'strscan'
require 'zlib'

module PDFRedactor
  ##
  # A PDF as qpdf --qdf writes it: objects in order, one per line start, and
  # a plain xref table. Reads objects and streams, and writes the file again
  # with edits, each a [start, stop) span of its bytes and what replaces it.
  class QdfDoc
    attr_reader :bytes, :trailer, :offsets

    IMAGE_FILTERS = %w[
      DCTDecode DCT JPXDecode JBIG2Decode CCITTFaxDecode CCF
    ].freeze
    # Page attributes a page takes from its parents.
    INHERITED = %w[Resources MediaBox CropBox Rotate].freeze
    MAX_OBJECTS = 100_000
    MAX_PAGES = 10_000
    MAX_DECODED_STREAM_BYTES = 128 * 1024 * 1024
    MAX_TOTAL_DECODED_BYTES = 512 * 1024 * 1024

    def initialize(bytes)
      @bytes = bytes.b
      @cache = {}
      @decoded_seen = Set.new
      @total_decoded_bytes = 0
      startxref = @bytes.rindex('startxref') or
        raise Error, 'PDF startxref is missing'
      off = @bytes.byteslice(startxref + 9, 30).to_i
      if off.negative? || off + 4 > @bytes.bytesize
        raise Error, 'PDF xref offset is out of range'
      end

      @offsets = {}
      sc = StringScanner.new(@bytes)
      sc.pos = off + 4
      sc.skip(/\s*/)
      while sc.scan(/(\d+) (\d+)\s*\r?\n/)
        first = sc[1].to_i
        count = sc[2].to_i
        if first + count > MAX_OBJECTS || @offsets.size + count > MAX_OBJECTS
          raise Error, 'PDF object limit exceeded'
        end

        count.times do |k|
          break unless sc.scan(/(\d{10}) (\d{5}) ([nf])\s*\r?\n?/)

          @offsets[first + k] = sc[1].to_i if sc[3] == 'n'
        end
      end
      trailer = @bytes.index('trailer', off) or
        raise Error, 'PDF trailer is missing'
      @trailer = Lexer.new(@bytes, trailer + 7).value
      raise Error, 'PDF trailer is invalid' unless @trailer.is_a?(Hash)
    end

    # { value:, stream: [start, len] | nil }
    def object(num)
      return @cache[num] if @cache.key?(num)

      off = @offsets[num]
      return @cache[num] = nil unless off

      lx = Lexer.new(@bytes, off)
      3.times { lx.value } # N G obj
      lx.skip_ws
      dict_start = lx.pos
      val = lx.value
      save = lx.pos
      stream = nil
      if lx.value == 'stream'
        p = lx.pos
        p += 1 if @bytes.getbyte(p) == 13
        p += 1 if @bytes.getbyte(p) == 10
        length = val.is_a?(Hash) ? resolve(val['Length']) : nil
        unless length.is_a?(Integer) && !length.negative?
          raise Error, 'PDF stream length is invalid'
        end

        stream = [p, length]
      else
        lx.pos = save
      end
      @cache[num] = { value: val, stream: stream, dict: [dict_start, save] }
    end

    def resolve(v, depth = 0)
      while v.is_a?(Ref) && depth < 20
        v = object(v.num)&.dig(:value)
        depth += 1
      end
      v
    end

    def name(v)
      v = resolve(v)
      v.is_a?(Name) ? v.name : nil
    end

    def stream_data(ref)
      return nil unless ref.is_a?(Ref) && (o = object(ref.num)) && o[:stream]

      decoded(ref.num).first
    end

    # [data, filters left] with every filter decoded up to the first image
    # filter, which stays.
    def decoded(num)
      o = object(num)
      data = @bytes.byteslice(*o[:stream])
      raise Error, 'PDF stream length is invalid' unless data

      fs = PDFRedactor.list(resolve(o[:value]['Filter'])).map { |f| name(f) }
      parms = resolve(o[:value]['DecodeParms'])
      parms = PDFRedactor.list(parms).map { |x| resolve(x) }
      fs.each_with_index do |f, i|
        if IMAGE_FILTERS.include?(f)
          return [account_decoded(num, data), fs[i..]]
        end

        raise NeedsFullDecode, f unless %w[FlateDecode Fl].include?(f)
        if parms[i].is_a?(Hash) && resolve(parms[i]['Predictor']).to_i > 1
          raise NeedsFullDecode, 'predictor'
        end

        begin
          data = inflate_bounded(data)
        rescue Zlib::Error
          raise NeedsFullDecode, 'damaged Flate data'
        end
      end
      [account_decoded(num, data), []]
    end

    # Edits that put new decoded data in a stream: the data, and the
    # dictionary without the filters that were decoded.
    def stream_edits(num, data, drop: [])
      o = object(num)
      _, rest = decoded(num)
      # The end-of-line before endstream is not part of /Length.
      edits = [[o[:stream][0], o[:stream][0] + o[:stream][1], data + "\n"]]
      length = o[:value]['Length']
      if length.is_a?(Ref) && (lo = object(length.num))
        edits << [*lo[:dict], data.bytesize.to_s]
      else
        drop += ['Length']
      end
      had = PDFRedactor.list(resolve(o[:value]['Filter']))
      return edits if had.size == rest.size && drop.empty?

      dict = o[:value].reject do |k, _|
        %w[Filter DecodeParms].include?(k) || drop.include?(k)
      end
      dict['Length'] = data.bytesize unless length.is_a?(Ref)
      unless rest.empty?
        names = rest.map { |f| Name.new(f) }
        dict['Filter'] = names.size == 1 ? names[0] : names
        parms = PDFRedactor.list(resolve(o[:value]['DecodeParms']))
        unless parms.empty?
          parms = parms.last(rest.size)
          dict['DecodeParms'] = parms.size == 1 ? parms[0] : parms
        end
      end
      edits << [*o[:dict], Serialize.dump(dict).b]
    end

    # The file with the edits made and the objects added, its xref table
    # rebuilt for the new offsets. This does the work of fix-qdf without a
    # second pass. An edit is [start, stop, bytes], or [start, stop, bytes,
    # :removal] for one that writes a whole object as null.
    def rewrite(edits, added = {})
      # By start, and the longer of two at the same start first, so the order
      # doesn't depend on the order they came in.
      edits = edits.sort_by { |s, e, _| [s, -e] }
      out = String.new(encoding: Encoding::BINARY,
                       capacity: @bytes.bytesize + 4096)
      starts = []
      deltas = []
      last = 0
      shift = 0
      removed = false
      edits.each do |s, e, rep, kind|
        if s < last
          # Inside an object that the edit before removes, nothing is left to
          # change. Any other overlap would lose one of the two edits, perhaps
          # a censored string, so the file is withheld instead.
          next if removed && e <= last

          raise Error, "two edits overlap at byte #{s}"
        end

        out << @bytes.byteslice(last, s - last) << rep
        last = e
        removed = kind == :removal
        shift += rep.bytesize - (e - s)
        starts << s
        deltas << shift
      end
      xref_at = @bytes.rindex('startxref')
      start = @bytes.byteslice(xref_at + 9, 30).to_i
      xref_at = @bytes.rindex('xref', start + 4) || xref_at
      out << @bytes.byteslice(last, xref_at - last)
      added_at = added.to_h do |num, object|
        at = out.bytesize
        out << object
        [num, at]
      end
      moved = ->(off) do
        i = starts.bsearch_index { |s| s >= off } || starts.size
        i.zero? ? off : off + deltas[i - 1]
      end
      size = [*@offsets.keys, *added.keys, 0].max + 1
      raise Error, 'PDF object limit exceeded' if size > MAX_OBJECTS

      new_xref = out.bytesize
      out << "xref\n0 #{size}\n0000000000 65535 f \n"
      (1...size).each do |n|
        out << if added_at[n]
                 format("%010d 00000 n \n", added_at[n])
               elsif @offsets[n]
                 format("%010d 00000 n \n", moved.call(@offsets[n]))
               else
                 "0000000000 00000 f \n"
               end
      end
      tr = @bytes.index('trailer', xref_at)
      out << @bytes.byteslice(tr, @bytes.rindex('startxref') - tr).
             sub(%r{/Size \d+}, "/Size #{size}")
      out << "startxref\n#{new_xref}\n%%EOF\n"
    end

    # This document, with a copy of each content stream for each page after
    # the first to use it. A stream is read by the resources of its page, and
    # edits to it can be for one page only (ISO 32000-1 7.8.3).
    def unshare_contents
      seen = Set.new
      added = {}
      edits = []
      next_num = (@offsets.keys.max || 0) + 1
      total_bytes = @bytes.bytesize
      pages.each do |page, _, _, ref|
        contents = resolve(page['Contents'])
        refs = contents.is_a?(Array) ? contents : [page['Contents']]
        own = refs.map do |r|
          next r unless r.is_a?(Ref)

          source = object(r.num)
          next r unless source&.dig(:stream)
          next r if seen.add?(r.num)

          raise Error, 'PDF object limit exceeded' if next_num >= MAX_OBJECTS

          stream_len = source[:stream][1].to_i
          raise Error, 'PDF stream length is invalid' if stream_len.negative?
          if total_bytes + stream_len > MAX_BYTES
            raise Error, 'PDF unshared content limit exceeded'
          end

          num = next_num
          next_num += 1
          copy = stream_copy(num, r.num)
          total_bytes += copy.bytesize
          if total_bytes > MAX_BYTES
            raise Error, 'PDF unshared content limit exceeded'
          end

          added[num] = copy
          Ref.new(num, 0)
        end
        next if own == refs

        own = own.first unless contents.is_a?(Array)
        edits << [*object(ref.num)[:dict],
                  Serialize.dump(page.merge('Contents' => own)).b]
      end
      added.empty? ? self : self.class.new(rewrite(edits, added))
    end

    def pages
      out = []
      walk = ->(ref, inherited, depth) do
        node = resolve(ref)
        raise Error, 'PDF page tree nesting limit exceeded' if depth >= 50
        return unless node.is_a?(Hash)

        attrs = inherited.merge(node.slice(*INHERITED))
        if node.key?('Kids')
          PDFRedactor.list(resolve(node['Kids'])).each do |k|
            walk.call(k, attrs, depth + 1)
          end
        else
          raise Error, 'PDF page limit exceeded' if out.size >= MAX_PAGES

          out << [node, resolve(attrs['Resources']), attrs, ref]
        end
      end
      root = resolve(@trailer['Root'])
      raise Error, 'PDF catalog is missing' unless root.is_a?(Hash)

      walk.call(root['Pages'], {}, 0)
      out
    end

    # The streams that are attached files: those that say so, and those a
    # file specification attaches, by /EF or as related files (/RF), as an
    # attached file's own /Type is optional (ISO 32000-1 Table 44). Redactor
    # and FinalScan both use this.
    def attached_streams
      found = Set.new
      offsets.each_key do |n|
        next unless (o = object(n))

        v = o[:value]
        found << n if o[:stream] && v.is_a?(Hash) &&
                      name(v['Type']) == 'EmbeddedFile'
        PDFRedactor.each_dict(v) do |dict|
          files = resolve(dict['EF'])
          found.merge(files.values.grep(Ref).map(&:num)) if files.is_a?(Hash)
          related = resolve(dict['RF'])
          next unless related.is_a?(Hash)

          # Each related files array pairs a name with a stream.
          related.each_value do |list|
            found.merge(PDFRedactor.list(resolve(list)).grep(Ref).map(&:num))
          end
        end
      end
      found
    end

    private

    def account_decoded(num, data)
      if data.bytesize > MAX_DECODED_STREAM_BYTES
        raise Error, 'PDF decoded stream limit exceeded'
      end

      unless @decoded_seen.include?(num)
        @total_decoded_bytes += data.bytesize
        if @total_decoded_bytes > MAX_TOTAL_DECODED_BYTES
          raise Error, 'PDF decoded data limit exceeded'
        end

        @decoded_seen << num
      end
      data
    end

    def inflate_bounded(data)
      inflater = Zlib::Inflate.new
      out = String.new(encoding: Encoding::BINARY)
      at = 0
      while at < data.bytesize
        out << inflater.inflate(data.byteslice(at, 16 * 1024))
        raise Error, 'PDF decoded stream limit exceeded' if
          out.bytesize > MAX_DECODED_STREAM_BYTES

        at += 16 * 1024
      end
      out << inflater.finish
      raise Error, 'PDF decoded stream limit exceeded' if
        out.bytesize > MAX_DECODED_STREAM_BYTES

      out
    ensure
      inflater&.close
    end

    # The object, with its own /Length as the original's may be shared too.
    def stream_copy(num, source)
      o = object(source)
      data = @bytes.byteslice(*o[:stream])
      raise Error, 'PDF stream length is invalid' if data.nil?

      dict = o[:value].merge('Length' => data.bytesize)
      "#{num} 0 obj\n#{Serialize.dump(dict)}\nstream\n".b + data +
        "\nendstream\nendobj\n".b
    end
  end
end
