# frozen_string_literal: true

module PDFRedactor
  # Base encodings for simple fonts (Annex D), as code -> Unicode.
  module Encodings
    module_function

    def [](name)
      @tables ||= {}
      @tables[name] ||= case name
                        when 'StandardEncoding' then Afm['Helvetica'].codes.dup
                        when 'WinAnsiEncoding' then win_ansi
                        when 'MacRomanEncoding' then mac_roman
                        end
    end

    # Windows code page 1252. In WinAnsiEncoding every unused code above 040
    # shows the bullet, 0240 is the space and 0255 the hyphen.
    def win_ansi
      (0..255).each_with_object({}) do |c, h|
        ch = begin
          c.chr.force_encoding('Windows-1252').encode('UTF-8')
             rescue EncodingError
               nil
        end
        ch = "•" if ch.nil? && c > 0o40
        ch = ' ' if c == 0o240
        ch = '-' if c == 0o255
        h[c] = ch if ch && c >= 0o40
      end
    end

    # Mac OS Roman. Annex D's MacRomanEncoding leaves out the Apple logo.
    def mac_roman
      (0o40..255).each_with_object({}) do |c, h|
        ch = c.chr.force_encoding('macRoman').encode('UTF-8')
        h[c] = c == 0o312 ? ' ' : ch unless c == 0xF0
      rescue EncodingError
        nil
      end
    end
  end
end
