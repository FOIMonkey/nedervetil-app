# Interpolates plain-text values without HTML entities and returns a plain
# String, so a later HTML renderer still escapes the result.
module PlainTextTranslation
  # Plain-text lookup for flashes, letters, subjects and stored messages.
  def self._(key, options = {})
    translation = (FastGettext._(key) || key).to_str
    gettext_interpolate(translation, options)
  end

  def self.n_(*keys)
    options = keys.extract_options!
    count = keys.pop.to_i
    translation = FastGettext.n_(*keys, count).to_str
    gettext_interpolate(translation, options)
  end

  # For text templates used by emails, downloads and form fields.
  module View
    def _(key, options = {})
      if formats.first == :text
        PlainTextTranslation._(key, options)
      else
        super
      end
    end

    def n_(*keys)
      return super unless formats.first == :text

      PlainTextTranslation.n_(*keys)
    end
  end

  # For mailers: subjects and headers are plain text.
  module Mailer
    private

    def _(key, options = {})
      PlainTextTranslation._(key, options)
    end

    def n_(*keys)
      PlainTextTranslation.n_(*keys)
    end
  end
end
