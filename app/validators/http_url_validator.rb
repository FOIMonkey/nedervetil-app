# Validates an http/https URL via HttpUrl; bare hosts (e.g. "example.org")
# pass and default to https://.
class HttpUrlValidator < ActiveModel::EachValidator
  def validate_each(record, attribute, value)
    return if value.blank?

    return if HttpUrl.with_default_scheme(value)

    record.errors.add(attribute, message)
  end

  private

  def message
    options[:message] ||
      _('must be a web address, such as https://www.example.org')
  end
end
