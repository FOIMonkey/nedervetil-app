# Validates a Topics::Topic link hash (authority, tag, http/https url, or
# external FOI site search).
class TopicLinkValidator < ActiveModel::EachValidator
  SHAPES = [%w[body], %w[tag], %w[url], %w[wdtk], %w[tag wdtk]].freeze

  def validate_each(record, attribute, value)
    return if value.blank?

    unless value.is_a?(Hash) && SHAPES.include?(value.keys.sort) &&
           value.values.all? { |each| each.is_a?(String) && each.present? }
      return record.errors.add(attribute, 'must name an authority, a tag, a ' \
                                          'web address or a search on the ' \
                                          'other site')
    end
    return if !value['url'] || TopicUrlValidator.web_address?(value['url'])

    record.errors.add(attribute, 'must link to an address starting http:// ' \
                                 'or https://')
  end
end
