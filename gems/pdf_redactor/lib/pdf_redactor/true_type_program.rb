# frozen_string_literal: true

module PDFRedactor
  # An embedded TrueType program (OpenType cmap): code -> glyph -> Unicode.
  # Counts expanded mappings, including repeated ranges, before allocating
  # them. Shared encoding records at one offset are decoded only once.
  class TrueTypeProgram
    InvalidFont = Class.new(StandardError)
    LimitExceeded = Class.new(InvalidFont)
    MAX_BYTES = 32 * 1024 * 1024
    # Per program: directory records, segments/groups, expanded character
    # codes and inverse entries all draw from the same work allowance.
    MAX_WORK = 1_000_000

    def initialize(data)
      raise LimitExceeded, 'embedded font byte limit exceeded' if
        data.bytesize > MAX_BYTES

      @d = data.b
      @work = 0
      @tables = {}
      bounds(0, 12)
      unless ["\x00\x01\x00\x00".b, 'true', 'OTTO'].include?(@d.byteslice(0, 4))
        raise InvalidFont, 'unsupported embedded font header'
      end

      count = u16(4)
      directory_end = 12 + (16 * count)
      bounds(12, 16 * count)
      consume(count)
      count.times do |i|
        tag, _sum, offset, length = bytes(12 + (16 * i), 16).unpack('a4NNN')
        bounds(offset, length)
        if @tables.key?(tag) || (length.positive? && offset < directory_end)
          raise InvalidFont, 'invalid embedded font table directory'
        end

        @tables[tag] = [offset, length]
      end
      @subtables = cmap_subtables
    end

    def glyph(code, *pairs)
      pairs.each do |pair|
        gid = @subtables[pair]&.[](code)
        return gid if gid&.positive?
      end
      nil
    end

    def has?(*pairs) = pairs.any? { |pair| @subtables.key?(pair) }

    def unicode_of(gid)
      @inverse ||= begin
        inverse = {}
        seen = {}.compare_by_identity
        [[3, 10], [3, 1], [0, 4], [0, 3]].each do |pair|
          map = @subtables[pair]
          next unless map && !seen[map]

          seen[map] = true
          consume(map.size)
          map.each do |code, glyph|
            unless code.between?(0xD800, 0xDFFF)
              inverse[glyph] ||= [code].pack('U')
            end
          end
        end
        inverse
      end
      @inverse[gid]
    end

    private

    # Checking a declared extent must not allocate a copy of its payload.
    def bounds(offset, length, limit = @d.bytesize)
      unless offset >= 0 && length >= 0 && limit <= @d.bytesize &&
             offset <= limit && length <= limit - offset
        raise InvalidFont, 'embedded font offset or length is out of bounds'
      end
    end

    def bytes(offset, length, limit = @d.bytesize)
      bounds(offset, length, limit)
      @d.byteslice(offset, length)
    end

    def u16(offset, limit = @d.bytesize) = bytes(offset, 2, limit).unpack1('n')
    def u32(offset, limit = @d.bytesize) = bytes(offset, 4, limit).unpack1('N')

    def consume(amount)
      @work += amount
      raise LimitExceeded, 'embedded font mapping work limit exceeded' if
        @work > MAX_WORK
    end

    def cmap_subtables
      out = {}
      return out unless @tables['cmap']

      base, length = @tables['cmap']
      limit = base + length
      unless u16(base, limit).zero?
        raise InvalidFont, 'unsupported cmap version'
      end

      count = u16(base + 2, limit)
      records_end = base + 4 + (8 * count)
      bounds(base + 4, 8 * count, limit)
      consume(count)
      cache = {}
      count.times do |i|
        pid, eid, relative = bytes(base + 4 + (8 * i), 8, limit).unpack('nnN')
        offset = base + relative
        if offset < records_end
          raise InvalidFont, 'cmap subtable overlaps encoding records'
        end

        cache[offset] = read_subtable(offset, limit) unless cache.key?(offset)
        map = cache[offset]
        next unless map

        out[[pid, eid]] ||= map
      end
      out
    end

    def read_subtable(offset, table_end)
      format = u16(offset, table_end)
      return nil unless [0, 4, 6, 12].include?(format)

      length = if format == 12
                 u32(offset + 4, table_end)
               else
                 u16(offset + 2, table_end)
               end
      bounds(offset, length, table_end)
      limit = offset + length
      case format
      when 0
        bounds(offset, 262, limit)
        consume(256)
        bytes(offset + 6, 256, limit).bytes.each_with_index.
          filter_map { |glyph, code| [code, glyph] if glyph.positive? }.to_h
      when 4
        format_four(offset, limit)
      when 6
        bounds(offset, 10, limit)
        first = u16(offset + 6, limit)
        count = u16(offset + 8, limit)
        raise InvalidFont, 'format 6 character range is invalid' if
          first + count > 0x10000

        consume(count)
        bytes(offset + 10, 2 * count, limit).unpack('n*').each_with_index.
          filter_map { |glyph, i| [first + i, glyph] if glyph.positive? }.to_h
      when 12
        format_twelve(offset, limit)
      end
    end

    def format_four(offset, limit)
      bounds(offset, 16, limit)
      size = u16(offset + 6, limit)
      raise InvalidFont, 'format 4 segment count is invalid' if
        size.zero? || size.odd?

      count = size / 2
      bounds(offset, 16 + (8 * count), limit)
      consume(count)
      ends = offset + 14
      starts = ends + (2 * count) + 2
      deltas = starts + (2 * count)
      offsets = deltas + (2 * count)
      glyphs = offsets + (2 * count)
      previous = -1
      segments = Array.new(count) do |i|
        first = u16(starts + (2 * i), limit)
        last = u16(ends + (2 * i), limit)
        delta = u16(deltas + (2 * i), limit)
        relative = u16(offsets + (2 * i), limit)
        if first > last || first <= previous || relative.odd?
          raise InvalidFont, 'format 4 segments overlap or are invalid'
        end

        previous = last
        address = offsets + (2 * i) + relative
        unless relative.zero?
          raise InvalidFont, 'format 4 glyph offset precedes glyph array' if
            address < glyphs

          bounds(address, 2 * (last - first + 1), limit)
        end
        [first, last, delta, relative.zero? ? nil : address]
      end
      unless segments.last[0, 2] == [0xFFFF, 0xFFFF]
        raise InvalidFont, 'format 4 sentinel is missing'
      end

      map = {}
      segments.each do |first, last, delta, address|
        next if first == 0xFFFF

        consume(last - first + 1)
        (first..last).each do |code|
          raw = address ? u16(address + (2 * (code - first)), limit) : code
          glyph = address && raw.zero? ? 0 : (raw + delta) & 0xFFFF
          map[code] = glyph if glyph.positive?
        end
      end
      map
    end

    def format_twelve(offset, limit)
      bounds(offset, 16, limit)
      count = u32(offset + 12, limit)
      bounds(offset + 16, 12 * count, limit)
      consume(count)
      previous = -1
      groups = Array.new(count) do |i|
        first, last, glyph = bytes(offset + 16 + (12 * i), 12, limit).
          unpack('NNN')
        if first > last || first <= previous || last > 0x10FFFF ||
           glyph + last - first > 0xFFFF
          raise InvalidFont, 'format 12 character or glyph range is invalid'
        end

        previous = last
        [first, last, glyph]
      end
      map = {}
      groups.each do |first, last, glyph|
        consume(last - first + 1)
        (first..last).each do |code|
          gid = glyph + code - first
          map[code] = gid if gid.positive?
        end
      end
      map
    end
  end
end
