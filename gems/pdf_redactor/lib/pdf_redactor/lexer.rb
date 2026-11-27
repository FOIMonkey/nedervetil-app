# frozen_string_literal: true

require 'strscan'

module PDFRedactor
  # Values are Integer, Float, Name, PStr, Ref, Array, Hash, true, false, nil.
  # A bare keyword (an operator) comes back as a String.
  class Lexer
    MAX_NESTING = 128
    MAX_TOKENS = 4_000_000
    WS_RE = /(?:[\x00\t\n\f\r ]+|%[^\r\n]*)+/n
    REG = '[^\x00\t\n\f\r ()<>\[\]{}/%]'
    NUM_RE = /[+-]?(?:\d+(?:\.\d*)?|\.\d+)(?!#{REG})/n
    REG_RE = /#{REG}+/n
    NAME_RE = %r{/(#{REG}*)}n
    HEX_RE = /<([0-9A-Fa-f\x00\t\n\f\r ]*)>/n
    PLAIN_LITERAL_RE = /\(([^()\\\r]*)\)/n
    REF_RE = /(\d+)[\x00\t\n\f\r ]+(\d+)[\x00\t\n\f\r ]+R(?!#{REG})/n
    EI_RE = /(?<=[\x00\t\n\f\r >])EI(?=[\x00\t\n\f\r ]|\z)/n
    ESC = {
      110 => "\n", 114 => "\r", 116 => "\t", 98 => "\b", 102 => "\f"
    }.freeze

    attr_reader :data

    def initialize(data, pos = 0, refs: true)
      @data = data.encoding == Encoding::BINARY ? data : data.b
      if pos.negative? || pos > @data.bytesize
        raise Error, 'PDF offset out of range'
      end

      @sc = StringScanner.new(@data)
      @sc.pos = pos
      @refs = refs
      @depth = 0
      @tokens = 0
    end

    # Yields each operator of a content stream with its operands and byte
    # span. The operand array is reused: dup it to keep it.
    def self.each_op(data)
      lx = Lexer.new(data, refs: false)
      args = []
      start = nil
      loop do
        lx.skip_ws
        s = lx.pos
        case (v = lx.value(false))
        when Symbol
          break if v == :eof
        when String
          lx.skip_inline_image if v == 'BI'
          yield v, args, start || s, lx.pos
          args.clear
          start = nil
        else
          start ||= s
          args << v
        end
      end
    end

    def pos = @sc.pos

    def pos=(value)
      @sc.pos = value
    end

    def skip_ws = @sc.skip(WS_RE)

    def value(skip = true)
      @sc.skip(WS_RE) if skip
      start = @sc.pos
      @tokens += 1
      raise Error, 'PDF token limit exceeded' if @tokens > MAX_TOKENS

      case (c = @data.getbyte(start))
      when nil then :eof
      when 0x2F
        @sc.scan(NAME_RE)
        n = @sc[1]
        if n.include?('#')
          n = n.gsub(/#(\h\h)/n) { Regexp.last_match(1).hex.chr }
        end
        Name.new(n)
      when 0x28
        bytes = @sc.scan(PLAIN_LITERAL_RE) ? @sc[1] : literal
        PStr.new(bytes, [start, @sc.pos])
      when 0x3C
        if @data.getbyte(start + 1) == 0x3C
          @sc.pos += 2
          dict
        elsif @sc.scan(HEX_RE)
          h = @sc[1].delete("\x00\t\n\f\r ")
          h << '0' if h.size.odd?
          PStr.new([h].pack('H*'), [start, @sc.pos])
        else
          @sc.pos += 1
          '<'
        end
      when 0x5B
        @sc.pos += 1
        array
      when 0x5D
        @sc.pos += 1
        :aclose
      when 0x3E
        @sc.pos += @data.getbyte(start + 1) == 0x3E ? 2 : 1
        :dclose
      when 0x30..0x39, 0x2B, 0x2D, 0x2E
        n = @sc.scan(NUM_RE)
        return keyword(c) unless n

        if @refs && !n.include?('.')
          save = @sc.pos
          @sc.pos = start
          return Ref.new(@sc[1].to_i, @sc[2].to_i) if @sc.scan(REF_RE)

          @sc.pos = save
        end
        n.include?('.') ? n.to_f : n.to_i
      else
        keyword(c)
      end
    end

    def keyword(c)
      if (k = @sc.scan(REG_RE))
        case k
        when 'true' then true
        when 'false' then false
        when 'null' then nil
        else k
        end
      else
        @sc.pos += 1
        c.chr
      end
    end

    # Skips an inline image after BI: its dictionary, ID and binary data.
    def skip_inline_image
      until (v = value) == :eof || v == 'ID'
      end
      return unless v == 'ID' && !@sc.eos?

      @sc.pos += 1
      @sc.skip_until(EI_RE) || (@sc.pos = @data.bytesize)
    end

    private

    def array
      enter_container
      out = []
      while (v = value) != :aclose && v != :eof
        out << v unless v == :dclose
      end
      out
    ensure
      @depth -= 1
    end

    def dict
      enter_container
      out = {}
      while (k = value) != :dclose && k != :eof
        next unless k.is_a?(Name)

        v = value
        out[k.name] = v unless v == :dclose || v == :eof
        break if v == :dclose || v == :eof
      end
      out
    ensure
      @depth -= 1
    end

    def enter_container
      @depth += 1
      raise Error, 'PDF nesting limit exceeded' if @depth > MAX_NESTING
    end

    def literal
      p = @sc.pos + 1
      depth = 1
      out = String.new(encoding: Encoding::BINARY)
      while (c = @data.getbyte(p))
        p += 1
        case c
        when 0x5C
          n = @data.getbyte(p)
          break unless n

          p += 1
          if (e = ESC[n]) then out << e
          elsif n && n >= 0x30 && n <= 0x37
            v = n - 0x30
            2.times do
              d = @data.getbyte(p)
              break unless d && d >= 0x30 && d <= 0x37

              v = (v * 8) + d - 0x30
              p += 1
            end
            out << (v & 0xff)
          elsif n == 0x0D
            p += 1 if @data.getbyte(p) == 0x0A
          elsif n && n != 0x0A
            out << n
          end
        when 0x28
          depth += 1
          out << c
        when 0x29
          depth -= 1
          break if depth.zero?

          out << c
        when 0x0D
          p += 1 if @data.getbyte(p) == 0x0A
          out << 0x0A
        else
          out << c
        end
      end
      @sc.pos = p
      out
    end
  end
end
