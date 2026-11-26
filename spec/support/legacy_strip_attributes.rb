# The strip_attributes gem's rule for one value (StripAttributes.strip_string
# in mysociety/strip_attributes 1.14.1, branch globalize3-rails8, MIT
# licence), copied so the models can be checked against it whatever tidies
# their text. The one change: it works on a copy instead of changing the
# value in place.
module LegacyStripAttributes
  MULTIBYTE_WHITE = "\u180E\u200B\u200C\u200D\u2060\uFEFF".freeze
  MULTIBYTE_SPACE = /[[:space:]#{MULTIBYTE_WHITE}]/
  MULTIBYTE_BLANK = /[[:blank:]#{MULTIBYTE_WHITE}]/

  def self.strip(value, allow_empty: false, collapse_spaces: false,
                 replace_newlines: false)
    return value unless value.is_a?(String)
    return value if value.frozen?

    value = value.dup

    if Encoding.compatible?(value, MULTIBYTE_SPACE)
      value.gsub!(/\A#{MULTIBYTE_SPACE}+|#{MULTIBYTE_SPACE}+\z/o, "")
    else
      value.strip!
    end

    value.gsub!(/[\r\n]+/, " ") if replace_newlines

    if collapse_spaces
      if Encoding.compatible?(value, MULTIBYTE_BLANK)
        value.gsub!(/#{MULTIBYTE_BLANK}+/o, " ")
      else
        value.squeeze!(" ")
      end
    end

    value.blank? && !allow_empty ? nil : value
  end
end
