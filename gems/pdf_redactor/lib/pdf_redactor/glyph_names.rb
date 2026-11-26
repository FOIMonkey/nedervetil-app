# frozen_string_literal: true

module PDFRedactor
  # Adobe Glyph List Specification: glyph name -> Unicode.
  module GlyphNames
    module_function

    def list(file)
      @lists ||= {}
      path = File.join(DATA_DIR, file)
      @lists[file] ||= File.foreach(path).each_with_object({}) do |line, h|
        next if line.start_with?('#') || !line.include?(';')

        name, codes = line.chomp.split(';')
        h[name] = codes.split.map { |c| c.to_i(16) }.pack('U*')
      end
    end

    # Drop any suffix after the first period, split ligatures on "_", and map
    # each part. A part that does not map maps to nothing; nil if no part maps.
    def to_unicode(name, dingbats: false)
      base = name.to_s.split('.', 2).first.to_s
      return nil if base.empty?

      out = base.split('_').map { |part| component(part, dingbats) }
      out.compact.empty? ? nil : out.join
    end

    def component(part, dingbats)
      if dingbats && list('zapfdingbats.txt').key?(part)
        return list('zapfdingbats.txt')[part]
      end
      return list('glyphlist.txt')[part] if list('glyphlist.txt').key?(part)

      if (m = part.match(/\Auni((?:[0-9A-F]{4})+)\z/))
        units = m[1].scan(/.{4}/).map { |h| h.to_i(16) }
        return nil if units.any? { |u| u.between?(0xD800, 0xDFFF) }

        return units.pack('U*')
      end
      if (m = part.match(/\Au([0-9A-F]{4,6})\z/))
        v = m[1].to_i(16)
        return nil if v.between?(0xD800, 0xDFFF) || v > 0x10FFFF

        return [v].pack('U')
      end
      nil
    end
  end
end
