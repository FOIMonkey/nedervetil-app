# frozen_string_literal: true

module PDFRedactor
  # A CMap (9.7.5, 9.10.3, Adobe TN 5411): codespace ranges, and either
  # code -> Unicode (ToUnicode) or code -> CID (encodings).
  class CMap
    MAX_WORK = 1_000_000
    attr_reader :ranges, :unicode, :cids, :wmode

    SECTION_RE = /\Abegin(codespacerange|bfchar|bfrange|cidchar|cidrange|
                  notdefchar|notdefrange)\z/x

    def initialize(bytes = nil)
      @ranges = [] # [length, low bytes, high bytes]
      @unicode = {} # key(len, code) -> String
      @cids = {}    # key(len, code) -> CID
      @wmode = 0
      @work = 0
      parse(bytes) if bytes
    end

    def self.key(len, code) = (len << 32) | code

    # 9.7.6.2: a code's length is the first codespace range, shortest
    # first, that its bytes fall in, byte by byte.
    def length_at(bytes, i)
      (1..4).each do |len|
        s = bytes.byteslice(i, len)
        break if s.nil? || s.bytesize < len

        fits = @ranges.any? { |l, lo, hi| l == len && within?(s, lo, hi) }
        return len if fits
      end
      # 9.7.6.3: an unmatched code takes the length of the ranges that
      # match its first byte, or the shortest.
      first = bytes.getbyte(i)
      hit = @ranges.select do |_, lo, hi|
        first.between?(lo.getbyte(0), hi.getbyte(0))
      end
      hit.map(&:first).min || @ranges.map(&:first).min || 1
    end

    # Each byte of s is within the range's bytes at the same place.
    def within?(s, lo, hi)
      (0...s.bytesize).all? do |k|
        s.getbyte(k).between?(lo.getbyte(k), hi.getbyte(k))
      end
    end

    def lengths = @ranges.map(&:first).uniq

    private

    def parse(bytes)
      lx = Lexer.new(bytes, refs: false)
      section = nil
      held = []
      last = nil
      until (v = lx.value) == :eof
        consume(1)
        case v
        when String
          if (m = v.match(SECTION_RE))
            section = m[1]
            held.clear
          elsif v.start_with?('end') then section = nil
          elsif v == 'usecmap' then use(last)
          end
        when Name
          if section.nil? && v.name == 'WMode'
            w = lx.value
            @wmode = w if w.is_a?(Integer)
          elsif section
            held << v
            held.clear if record_entry?(section, held)
          end
        else
          if section
            held << v
            held.clear if record_entry?(section, held)
          end
        end
        last = v
      end
    end

    # A predefined CMap named by usecmap: only its codespace is known here.
    def use(name)
      return unless name.is_a?(Name)

      PredefinedCMaps.ranges(name.name)&.each { |r| @ranges << r }
    end

    # Records held as an entry of the section once it has all of one
    # entry's operands, and says whether it did.
    def record_entry?(section, held)
      case section
      when 'codespacerange'
        return false if held.size < 2

        lo, hi = held
        if lo.is_a?(PStr) && hi.is_a?(PStr) &&
           (1..4).cover?(lo.bytes.bytesize) &&
           lo.bytes.bytesize == hi.bytes.bytesize
          consume(1)
          @ranges << [lo.bytes.bytesize, lo.bytes, hi.bytes]
        end
      when 'bfchar'
        return false if held.size < 2

        src, dst = held
        if src.is_a?(PStr) && (unicode = target(dst))
          consume(1)
          @unicode[key(src)] = unicode
        end
      when 'bfrange'
        return false if held.size < 3

        lo, hi, dst = held
        bf_range(lo, hi, dst) if lo.is_a?(PStr) && hi.is_a?(PStr)
      when 'cidchar'
        return false if held.size < 2

        if held[0].is_a?(PStr) && held[1].is_a?(Integer)
          consume(1)
          @cids[key(held[0])] = held[1]
        end
      when 'cidrange'
        return false if held.size < 3

        lo, hi, cid = held
        if lo.is_a?(PStr) && hi.is_a?(PStr) && cid.is_a?(Integer) &&
           (1..4).cover?(lo.bytes.bytesize) &&
           lo.bytes.bytesize == hi.bytes.bytesize
          len = lo.bytes.bytesize
          a = PDFRedactor.int(lo.bytes)
          b = [PDFRedactor.int(hi.bytes), a + 0xFFFF].min
          consume(b - a + 1) if b >= a
          (a..b).each { |c| @cids[CMap.key(len, c)] = cid + c - a }
        end
      when 'notdefchar' then return held.size >= 2
      when 'notdefrange' then return held.size >= 3
      end
      true
    end

    def key(str) = CMap.key(str.bytes.bytesize, PDFRedactor.int(str.bytes))

    # A bfchar target is UTF-16BE, or (TN 5014) a glyph name.
    def target(dst)
      return PDFRedactor.utf16be(dst.bytes) if dst.is_a?(PStr)

      GlyphNames.to_unicode(dst.name) if dst.is_a?(Name)
    end

    # The destination string's last UTF-16 unit counts up across the range;
    # or each code takes its own string from an array.
    def bf_range(lo, hi, dst)
      len = lo.bytes.bytesize
      return unless (1..4).cover?(len) && hi.bytes.bytesize == len

      a = PDFRedactor.int(lo.bytes)
      b = [PDFRedactor.int(hi.bytes), a + 0xFFFF].min
      return if b < a

      if dst.is_a?(Array)
        consume([dst.size, b - a + 1].min)
        dst.each_with_index do |d, k|
          break if a + k > b

          mapped = target(d)
          @unicode[CMap.key(len, a + k)] = mapped if mapped
        end
      elsif dst.is_a?(PStr) && dst.bytes.bytesize >= 2
        consume(b - a + 1)
        u = dst.bytes.unpack('n*')
        last = u[-1]
        (a..b).each do |c|
          u[-1] = last + (c - a)
          @unicode[CMap.key(len, c)] = PDFRedactor.utf16be(u.pack('n*'))
        end
      elsif dst.is_a?(PStr) && dst.bytes.bytesize == 1
        consume(b - a + 1)
        first = dst.bytes.getbyte(0)
        (a..b).each do |c|
          point = first + c - a
          # A surrogate is not a character, so its code maps to nothing.
          next if point.between?(0xD800, 0xDFFF)

          @unicode[CMap.key(len, c)] = point.chr(Encoding::UTF_8)
        end
      end
    end

    def consume(amount)
      @work += amount
      raise Error, 'PDF CMap work limit exceeded' if @work > MAX_WORK
    end
  end
end
