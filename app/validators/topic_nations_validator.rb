# Validates a list of topic nations (empty means all), or with `map: true`
# a nation-to-non-blank-string hash.
class TopicNationsValidator < ActiveModel::EachValidator
  MESSAGE = 'must be England, Scotland, Wales or Northern Ireland'.freeze
  MAP_MESSAGE = 'must give a value for each of its nations, from England, ' \
                'Scotland, Wales and Northern Ireland'.freeze

  def validate_each(record, attribute, value)
    nations = options[:map] ? map_nations(value) : value
    return if nations && (nations - Topics::Topic::NATIONS.keys).empty?

    record.errors.add(attribute, options[:map] ? MAP_MESSAGE : MESSAGE)
  end

  private

  def map_nations(value)
    return unless value.is_a?(Hash)

    filled = value.values.all? { |word| word.is_a?(String) && word.present? }
    value.keys if filled
  end
end
