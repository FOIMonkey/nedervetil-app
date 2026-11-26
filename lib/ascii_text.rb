# Transliterates Latin text to plain ASCII for URL slugs and spam matching.
# Strips accents/format chars and normalizes dashes and quotes; non-Latin
# scripts map to "?". Always uses I18n's built-in table so slugs do not vary
# with configured site locales.
module AsciiText
  DASHES = /[‐-―−﹘﹣－]/

  QUOTES = {
    '‘' => "'", '’' => "'", '‚' => "'", '‛' => "'", '‹' => "'", '›' => "'",
    '“' => '"', '”' => '"', '„' => '"', '‟' => '"', '«' => '"', '»' => '"'
  }.freeze

  QUOTE_MARKS = Regexp.union(QUOTES.keys)

  # Cyrillic/Greek visual lookalikes mapped to Latin letters to defeat spam
  # obfuscation (by appearance, not sound, e.g. Greek η -> n).
  LOOKALIKES = {
    'ƒ' => 'f',
    'А' => 'A', 'В' => 'B', 'Е' => 'E', 'К' => 'K', 'М' => 'M', 'Н' => 'H',
    'О' => 'O', 'Р' => 'P', 'С' => 'C', 'Т' => 'T', 'У' => 'Y', 'Х' => 'X',
    'І' => 'I', 'Ј' => 'J', 'Ѕ' => 'S', 'Ӏ' => 'I', 'Һ' => 'H', 'Ө' => 'O',
    'Ѻ' => 'O',
    'а' => 'a', 'е' => 'e', 'к' => 'k', 'о' => 'o', 'р' => 'p', 'с' => 'c',
    'у' => 'y', 'х' => 'x', 'і' => 'i', 'ј' => 'j', 'ѕ' => 's', 'һ' => 'h',
    'ԁ' => 'd', 'ԛ' => 'q', 'ԝ' => 'w', 'ӏ' => 'l', 'ү' => 'y', 'т' => 't',
    'п' => 'n', 'ө' => 'o', 'ѻ' => 'o',
    'Α' => 'A', 'Β' => 'B', 'Ε' => 'E', 'Ζ' => 'Z', 'Η' => 'H', 'Ι' => 'I',
    'Κ' => 'K', 'Μ' => 'M', 'Ν' => 'N', 'Ο' => 'O', 'Ρ' => 'P', 'Τ' => 'T',
    'Υ' => 'Y', 'Χ' => 'X', 'Ϳ' => 'J',
    'α' => 'a', 'ι' => 'i', 'κ' => 'k', 'ν' => 'v', 'ο' => 'o', 'ρ' => 'p',
    'υ' => 'u', 'τ' => 't', 'ε' => 'e', 'η' => 'n', 'ω' => 'w', 'γ' => 'y',
    'χ' => 'x', 'μ' => 'u', 'ϳ' => 'j'
  }.freeze

  LOOKALIKE_LETTERS = Regexp.union(LOOKALIKES.keys)

  module_function

  # lookalikes: true maps LOOKALIKES first (for spam checks only; would mangle
  # non-Latin URL slugs).
  def transliterate(text, lookalikes: false)
    text = text.unicode_normalize(:nfkd).gsub(/[\p{Mn}\p{Cf}]/, '')
    text = text.gsub(LOOKALIKE_LETTERS, LOOKALIKES) if lookalikes
    text = text.gsub(DASHES, '-').gsub(QUOTE_MARKS, QUOTES)
    I18n::Backend::Transliterator.get.transliterate(text)
  end
end
