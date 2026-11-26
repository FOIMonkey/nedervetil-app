# frozen_string_literal: true

module PDFRedactor
  # The Core 14 AFM files: built-in encodings, widths and vertical metrics.
  module Afm
    # widths: Unicode -> width; codes: code -> Unicode.
    Metrics = Struct.new(:widths, :codes, :ascent, :descent)

    STANDARD_14 = %w[
      Courier Courier-Bold Courier-BoldOblique Courier-Oblique
      Helvetica Helvetica-Bold Helvetica-BoldOblique Helvetica-Oblique
      Symbol Times-Bold Times-BoldItalic Times-Italic Times-Roman ZapfDingbats
    ].freeze

    module_function

    def [](name)
      return nil unless STANDARD_14.include?(name)

      @fonts ||= {}
      @fonts[name] ||= begin
        dingbats = name == 'ZapfDingbats'
        widths = {}
        codes = {}
        ascent = descent = nil
        File.foreach(File.join(DATA_DIR, 'afm', "#{name}.afm")) do |line|
          if line.start_with?('C ')
            f = line.split(';').to_h { |part|
  k, v = part.strip.split(' ', 2)
  [k, v]
}
            u = GlyphNames.to_unicode(f['N'], dingbats: dingbats)
            next unless u

            widths[u] ||= f['WX'].to_f
            code = f['C'].to_i
            codes[code] = u if code.between?(0, 255)
          elsif line.start_with?('Ascender ') then ascent = line.split[1].to_f
          elsif line.start_with?('Descender ') then descent = line.split[1].to_f
          end
        end
        Metrics.new(widths, codes, ascent, descent)
      end
    end

    # Names that viewers treat as one of the 14, without the subset tag.
    def standard_name(base_font)
      n = base_font.to_s.sub(/\A[A-Z]{6}\+/, '')
      return n if STANDARD_14.include?(n)

      family, style = n.split(/[,-]/, 2)
      style = style.to_s.sub(/MT\z|PS\z|PSMT\z/, '')
      fam = case family.to_s.sub(/MT\z|PS\z|PSMT\z/, '')
            when 'Arial', 'Helvetica' then 'Helvetica'
            when 'TimesNewRoman', 'Times' then 'Times'
            when 'CourierNew', 'Courier' then 'Courier'
            end
      return nil unless fam

      bold = style.match?(/Bold/i)
      italic = style.match?(/Italic|Oblique/i)
      slant = fam == 'Times' ? 'Italic' : 'Oblique'
      suffix = if bold && italic then "-Bold#{slant}"
               elsif bold then '-Bold'
               elsif italic then "-#{slant}"
               else fam == 'Times' ? '-Roman' : ''
               end
      "#{fam}#{suffix}"
    end
  end
end
