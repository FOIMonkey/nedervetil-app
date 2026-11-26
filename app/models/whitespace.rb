# Text normalisation helpers for ActiveRecord `normalizes` declarations.
module Whitespace
  # Invisible characters outside [[:space:]]: MVS, ZWSP, ZWNJ, ZWJ, WJ, BOM.
  INVISIBLE = "\u180E\u200B\u200C\u200D\u2060\uFEFF".freeze
  SPACE = /[[:space:]#{INVISIBLE}]/
  ENDS = /\A#{SPACE}+|#{SPACE}+\z/
  BLANKS = /[[:blank:]#{INVISIBLE}]+/
  LINE_BREAKS = /[\r\n]+/

  module_function

  def trim(value)
    return value unless value.is_a?(String)

    if Encoding.compatible?(value, SPACE)
      value.gsub(ENDS, '')
    else
      # Fall back to ASCII strip for incompatible encodings.
      value.strip
    end
  end

  def trim_to_nil(value)
    nil_if_blank(trim(value))
  end

  def one_line(value)
    value = trim(value)
    return value unless value.is_a?(String)

    value = value.gsub(LINE_BREAKS, ' ')
    value = if Encoding.compatible?(value, BLANKS)
              value.gsub(BLANKS, ' ')
            else
              value.squeeze(' ')
            end
    nil_if_blank(value)
  end

  def nil_if_blank(value)
    value.is_a?(String) && value.blank? ? nil : value
  end

  TRIM = method(:trim).to_proc
  TRIM_TO_NIL = method(:trim_to_nil).to_proc
  ONE_LINE = method(:one_line).to_proc
end
