# frozen_string_literal: true

module PDFRedactor
  # One font resource. Widths are in thousandths of text space.
  class Font
    attr_reader :name, :type0, :code_size, :ascent, :descent,
                :vertical

    SYMBOLIC = 4
    SYMBOL_FONTS =
      /Wingdings|Webdings|Dingbat|Symbol|Marlett|MT Extra|Bookshelf/i

    def initialize(doc, dict)
      @doc = doc
      @dict = dict
      @subtype = doc.name(dict['Subtype'])
      @type0 = @subtype == 'Type0'
      @name = doc.name(dict['BaseFont']) || '?'
      @cid_font = descendant || {} if @type0
      @descriptor = doc.resolve((@cid_font || dict)['FontDescriptor'])
      @descriptor = {} unless @descriptor.is_a?(Hash)
      @standard = Afm.standard_name(@name) unless embedded?
      @to_unicode = (s = doc.stream_data(dict['ToUnicode'])) ? CMap.new(s) : nil
      @type0 ? composite_setup : simple_setup
      load_widths
      load_metrics
    end

    # [codes, lengths]; lengths is nil when every code has the font's size.
    def codes(bytes)
      return [bytes.unpack('C*'), nil] unless @type0
      return [bytes.unpack('n*'), nil] if @fixed == 2 && bytes.bytesize.even?

      out = []
      lens = []
      i = 0
      while i < bytes.bytesize
        n = [@encoding.length_at(bytes, i), bytes.bytesize - i].min
        out << PDFRedactor.int(bytes.byteslice(i, n))
        lens << n
        i += n
      end
      [out, lens]
    end

    # 9.10.2: the ToUnicode CMap; else the encoding's glyph names; else, for
    # a Uni... CMap, the code itself; else the font program's own cmap.
    def unicode(code, len = @code_size)
      @memo ||= {}
      @memo[CMap.key(len, code)] ||= find_unicode(code, len) || REPLACEMENT
    end

    def width(code, len = @code_size)
      w = if @type0 then @cid_widths.fetch(cid(code, len), @dw)
          else
            @widths.fetch(code) { standard_width(code) || @missing }
          end
      @font_matrix ? w * @font_matrix * 1000 : w
    end

    # Vertical advance (9.7.4.3), in thousandths, for vertical writing.
    def vertical_advance(code, len = @code_size)
      @cid_w2.fetch(cid(code, len), @dw2)
    end

    def code_bytes(code, len = @code_size)
      [code].pack('N').byteslice(4 - len, len)
    end

    private

    def descendant
      resolve_list(@dict['DescendantFonts']).map { |x| @doc.resolve(x) }.
        find { |x| x.is_a?(Hash) }
    end

    def resolve_list(v)
      v = @doc.resolve(v)
      if v.is_a?(Array)
        v
      else
        (v.nil? ? [] : [v])
      end
    end

    def num(v) = (v = @doc.resolve(v)).is_a?(Numeric) ? v.to_f : nil

    def embedded? = %w[FontFile FontFile2 FontFile3].any? { |k| @descriptor[k] }

    def symbolic? = (num(@descriptor['Flags']).to_i & SYMBOLIC) != 0

    # 9.7: the Encoding CMap gives code lengths and CIDs.
    def composite_setup
      enc = @doc.resolve(@dict['Encoding'])
      @cmap_name = enc.is_a?(Name) ? enc.name : nil
      @encoding = CMap.new
      if @cmap_name
        ranges = PredefinedCMaps.ranges(@cmap_name) ||
                 PredefinedCMaps.ranges('Identity-H')
        @encoding.ranges.concat(ranges)
        @vertical = PredefinedCMaps.vertical?(@cmap_name)
      elsif (s = @doc.stream_data(@dict['Encoding']))
        @encoding = CMap.new(s)
        if @encoding.ranges.empty?
          @encoding.ranges << [2, "\x00\x00".b, "\xFF\xFF".b]
        end
        @vertical = @encoding.wmode == 1
      end
      lens = @encoding.lengths
      @code_size = lens.min || 2
      @fixed = lens == [2] ? 2 : nil
      @identity = @cmap_name.to_s.start_with?('Identity-')
    end

    def cid(code, len)
      return code if @identity || @cmap_name

      @encoding.cids.fetch(CMap.key(len, code), code)
    end

    # 9.6.6: the base encoding, the font's built-in one when there is no
    # other, then /Differences.
    def simple_setup
      @code_size = 1
      if @subtype == 'Type3'
        @font_matrix = num(resolve_list(@dict['FontMatrix'])[0])
      end
      enc = @doc.resolve(@dict['Encoding'])
      base_name = if enc.is_a?(Name)
                    enc.name
                  else
                    (enc.is_a?(Hash) ? @doc.name(enc['BaseEncoding']) : nil)
                  end
      @table = (Encodings[base_name] || builtin_encoding || {}).dup
      return unless enc.is_a?(Hash)

      code = 0
      resolve_list(enc['Differences']).each do |x|
        x = @doc.resolve(x)
        if x.is_a?(Integer) then code = x
        elsif x.is_a?(Name)
          u = GlyphNames.to_unicode(x.name,
                                    dingbats: @standard == 'ZapfDingbats')
          u ? @table[code] = u : @table.delete(code)
          code += 1
        end
      end
    end

    # For a font with no Encoding: a standard 14 font's own encoding, the
    # Type 1 program's, a nonsymbolic font's StandardEncoding, or nothing.
    def builtin_encoding
      return Afm[@standard].codes if @standard
      return type1_encoding if @descriptor['FontFile']
      return nil if symbolic? && @subtype == 'TrueType'

      Encodings['StandardEncoding'] unless @subtype == 'Type3'
    end

    # Adobe Type 1 Font Format 2.3: the clear text before eexec holds the
    # encoding, StandardEncoding or "dup code /name put" entries.
    def type1_encoding
      clear = @doc.stream_data(@descriptor['FontFile'])&.
              split('eexec', 2)&.first
      if clear.nil? || clear.match?(%r{/Encoding\s+StandardEncoding\s+def})
        return Encodings['StandardEncoding']
      end

      table = {}
      clear.scan(%r{dup\s+(\d+)\s*/([^\s/\[\]{}()<>]+)\s+put}n) do |c, n|
        u = GlyphNames.to_unicode(n)
        table[c.to_i] = u if u && c.to_i < 256
      end
      table.empty? ? Encodings['StandardEncoding'] : table
    end

    def find_unicode(code, len)
      if @to_unicode
        u = @to_unicode.unicode[CMap.key(len, code)]
        # Not in the spec: Ghostscript and others write a simple font's
        # one-byte codes as two-byte ToUnicode codes, so match by value.
        if (u.nil? || u.empty?) && len <= 2 && code < 0x100
          u = @to_unicode.unicode[CMap.key(3 - len, code)]
        end
        return u if u && !u.empty?
      end
      if @type0
        if @cmap_name && !@identity
          u = PredefinedCMaps.unicode(@cmap_name, code_bytes(code, len))
          return u if u
        end
      elsif @table[code]
        return @table[code]
      end
      program_unicode(code, len) || (last_resort(code) unless @type0)
    end

    # Not in the spec: what viewers do with a code nothing maps. Tab, line
    # feed and return draw nothing; a text font's printable ASCII code is
    # usually that character, though the font may be flagged symbolic.
    def last_resort(code)
      return ' ' if [9, 10, 13].include?(code)

      code.chr if code.between?(0x20, 0x7E) && !@name.match?(SYMBOL_FONTS)
    end

    # Not in the spec's list, but a TrueType program often still holds a
    # Unicode cmap that gives each glyph's character.
    def program_unicode(code, len)
      tt = truetype
      return nil unless tt

      gid = if @type0
              c = cid(code, len)
              @cid_to_gid ? @cid_to_gid[c] : c
            else
              tt.glyph(code, [1, 0], [3, 0]) ||
                [0xF000, 0xF100, 0xF200].lazy.
                  filter_map { |base| tt.glyph(base + code, [3, 0]) }.first
            end
      gid && tt.unicode_of(gid)
    rescue TrueTypeProgram::InvalidFont => e
      raise Error, "Embedded TrueType font could not be read: #{e.message}"
    end

    def truetype
      return @truetype if defined?(@truetype)

      data = @doc.stream_data(@descriptor['FontFile2'])
      @truetype = data && TrueTypeProgram.new(data)
      map = @type0 && @truetype && @doc.stream_data(@cid_font['CIDToGIDMap'])
      @cid_to_gid = map.unpack('n*') if map
      @truetype
    rescue TrueTypeProgram::InvalidFont
      raise
    rescue StandardError
      @truetype = nil
    end

    def standard_width(code)
      return nil unless @standard && (m = Afm[@standard]) && (u = @table[code])

      m.widths[u]
    end

    def load_widths
      if @type0
        @dw = num(@cid_font['DW']) || 1000.0
        @cid_widths = cid_widths(resolve_list(@cid_font['W']), 1)
        dw2 = resolve_list(@cid_font['DW2']).map { |v| num(v) }
        @dw2 = dw2[1] || -1000.0
        @cid_w2 = cid_widths(resolve_list(@cid_font['W2']), 3).
                  transform_values { |v| v.is_a?(Array) ? v[0] : v }
      else
        @missing = num(@descriptor['MissingWidth']) || (@standard ? 0.0 : 500.0)
        first = num(@dict['FirstChar']).to_i
        @widths = {}
        resolve_list(@dict['Widths']).each_with_index do |w, k|
          (v = num(w)) && @widths[first + k] = v
        end
      end
    end

    # The W array (9.7.4.3): "c [w ...]" or "c_first c_last w"; for W2
    # each entry is three numbers (w1y, vx, vy). Poppler 25.03 was measured
    # with pdftotext -bbox, and a damaged width is read as it reads one, so
    # that a box goes where it draws the glyph: in a list, a width that isn't
    # a number (for W2, three values that aren't all numbers) is passed over
    # and the next takes its CID, and a range whose width isn't a number, or
    # that is cut short, is left out. Reading stops at a value that should be
    # a CID and isn't, so the CIDs after it keep the default. Poppler starts
    # again from the next value there, which reads widths as CIDs, so that is
    # not copied.
    def cid_widths(w, step)
      out = {}
      w = w.map { |x| @doc.resolve(x) }
      i = 0
      while i < w.size
        first = w[i]
        break unless first.is_a?(Integer)

        if w[i + 1].is_a?(Array)
          cid = first
          w[i + 1].map { |x| num(x) }.each_slice(step) do |v|
            next unless v.size == step && v.all?

            out[cid] = step == 1 ? v[0] : v
            cid += 1
          end
          i += 2
        else
          last = w[i + 1]
          break unless last.is_a?(Integer)

          vals = w[i + 2, step].map { |x| num(x) }
          width = step == 1 ? vals[0] : vals
          if (last - first) < 0x10000 && vals.size == step && vals.all?
            (first..last).each { |c| out[c] = width }
          end
          i += 2 + step
        end
      end
      out
    end

    def load_metrics
      afm = @standard && Afm[@standard]
      a = num(@descriptor['Ascent']) || afm&.ascent
      d = num(@descriptor['Descent']) || afm&.descent
      @ascent = (a&.positive? ? a / 1000.0 : 0.8).clamp(0.6, 1.1)
      @descent = (d&.negative? ? d / 1000.0 : -0.2).clamp(-0.4, -0.1)
    end
  end
end
