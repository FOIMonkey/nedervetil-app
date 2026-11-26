module Topics
  # Read-only official/open dataset loaded from TopicDataset. Direct kinds
  # (table, lookup) answer questions; `area_url` interpolates an ONS `gss:` tag.
  class Dataset
    KINDS = %w[table lookup collection home].freeze
    DIRECT = %w[table lookup].freeze
    STATUSES = %w[accredited official management register open].freeze
    KEYS = %w[
      id publisher title table answers url kind geography nations coverage
      frequency status area_url area_codes area_tested api
    ].freeze

    attr_reader :id, :publisher, :title, :table, :answers, :url, :kind,
                :geography, :nations, :coverage, :frequency, :status,
                :area_url, :area_codes, :area_tested, :api

    class << self
      def all
        index.values
      end

      def find(id)
        index[id]
      end

      def index
        Content.current.datasets
      end
    end

    def initialize(data)
      unknown = data.keys - KEYS
      if unknown.any?
        raise ArgumentError, "#{data['id']}: unknown keys #{unknown.join(', ')}"
      end

      KEYS.each { |key| instance_variable_set("@#{key}", data[key]) }
      @nations ||= Topic::NATIONS.keys
      @area_codes ||= []
      unless KINDS.include?(kind)
        raise ArgumentError, "#{id}: kind must be one of #{KINDS.join(', ')}"
      end
      unless STATUSES.include?(status)
        raise ArgumentError,
              "#{id}: status must be one of #{STATUSES.join(', ')}"
      end
      if area_url && (!area_url.include?('{gss}') || area_codes.empty?)
        raise ArgumentError, "#{id}: area_url needs {gss} and area_codes"
      end
    end

    def direct?
      DIRECT.include?(kind)
    end

    def for?(nation)
      nations.include?(nation)
    end

    # Not get_tag_values, which raises for a body with no gss: tag.
    def url_for(body)
      codes = area_url &&
              body.tags.select { |tag| tag.name == 'gss' }.filter_map(&:value)
      code = codes&.find do |value|
        area_codes.any? { |prefix| value.start_with?(prefix) }
      end
      code ? area_url.sub('{gss}', ERB::Util.url_encode(code)) : url
    end

    def area?(body)
      url_for(body) != url
    end
  end
end
