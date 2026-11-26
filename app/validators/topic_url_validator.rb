# Validates a full http/https URL with host for Topics::Topic links; unlike
# HttpUrlValidator, bare hosts are rejected.
class TopicUrlValidator < ActiveModel::EachValidator
  def self.web_address?(value)
    uri = URI.parse(value)
    uri.is_a?(URI::HTTP) && uri.host.present?
  rescue URI::InvalidURIError, TypeError
    false
  end

  def validate_each(record, attribute, value)
    return if value.blank? || self.class.web_address?(value)

    record.errors.add(attribute, 'must be a web address starting http:// or ' \
                                 'https://')
  end
end
