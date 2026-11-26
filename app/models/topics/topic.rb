module Topics
  # Read-only topic definition loaded from TopicPage data. Raises on unknown
  # keys, invalid URLs, or duplicate question slugs within a nation.
  class Topic
    NATIONS = { 'england' => N_('England'),
                'scotland' => N_('Scotland'),
                'wales' => N_('Wales'),
                'northern_ireland' => N_('Northern Ireland') }.freeze

    # Limits a row to the nations it lists (all nations when it lists none).
    module ForNations
      def for?(nation)
        nations.blank? || nations.include?(nation)
      end
    end

    # Stable key for per-authority holds_not:<key> tags across nations.
    Holder = Struct.new(:what, :key, :who, :nations, :where, :to, :groups,
                        :note, keyword_init: true) do
      include ForNations
    end
    # `dataset` is a single id or per-nation hash; questions for different
    # nations may share a `slug` so nation tabs keep the same path.
    Question = Struct.new(:text, :slug, :dataset, :partial, :published,
                          :published_label, :ask, :nations, :keywords,
                          :holder, :warning, :warning_title, :warning_text,
                          :heading, :note,
                          keyword_init: true) do
      include ForNations

      def slug
        self[:slug].presence || text.to_s.parameterize
      end

      def dataset_for(nation)
        id = dataset.is_a?(Hash) ? dataset[nation] : dataset
        id && Dataset.find(id)&.then { |found| found if found.for?(nation) }
      end

      def published_url(nation)
        dataset_for(nation)&.url || published
      end

      def published_for?(nation)
        published_url(nation).present?
      end

      def useful_for?(nation)
        for?(nation) && (ask.present? || published_for?(nation))
      end
    end
    Published = Struct.new(:label, :url, :note, :nations, keyword_init: true) do
      include ForNations
    end
    Elsewhere = Struct.new(:what, :route, :to, :note, :nations,
                           keyword_init: true) do
      include ForNations
    end

    HOME = 6
    RESERVED = %w[who-holds-it].freeze
    SLUG = /\A[a-z0-9]+(-[a-z0-9]+)*\z/

    attr_reader :slug, :title, :summary, :order, :search, :documents, :holders,
                :questions, :published, :elsewhere, :refused

    class << self
      def all
        Content.current.topics
      end

      def home
        all.first(HOME)
      end

      def find(slug)
        all.find { |topic| topic.slug == slug }
      end

      def holder_pairs
        all.
          flat_map { |topic| topic.holders.map { |holder| [holder, topic] } }
      end
    end

    def initialize(slug, data)
      @slug = slug
      @title = data.fetch('title')
      @summary = data.fetch('summary')
      @order = data.fetch('order')
      @search = data['search']
      @documents = Array(data['documents'])
      @holders = rows(data, 'holders', Holder)
      @questions = rows(data, 'questions', Question)
      @published = rows(data, 'published', Published)
      @elsewhere = rows(data, 'elsewhere', Elsewhere)
      @refused = data.fetch('refused', [])
      @elsewhere_heading = data.fetch('elsewhere_heading', :default)
      @titles = data.fetch('titles', {})
      validate_urls
      validate_documents
      validate_slugs
      unknown = data.keys - %w[
        title titles summary order search holders questions published elsewhere
        refused elsewhere_heading documents
      ]
      raise ArgumentError, "#{slug}: unknown keys #{unknown.join(', ')}" if
        unknown.any?
    end

    def question(slug)
      questions.find { |question| question.slug == slug }
    end

    def title_for(nation)
      @titles.fetch(nation.to_s, title)
    end

    def elsewhere_heading
      if @elsewhere_heading == :default
        _('Other routes')
      else
        @elsewhere_heading
      end
    end

    def links
      holders.map(&:to) +
        holders.flat_map do |holder|
          (holder.groups || []).map { |group| group.slice('tag') }
        end +
        questions.map(&:ask) + elsewhere.map(&:to)
    end

    private

    def validate_urls
      urls = links.compact.filter_map { |link| link['url'] } +
             published.map(&:url) + questions.map(&:published)
      urls.compact.each do |url|
        uri = URI.parse(url)
        unless uri.is_a?(URI::HTTP) && uri.host.present?
          raise ArgumentError, "#{slug}: links must use HTTP or HTTPS"
        end
      end
    rescue URI::InvalidURIError
      raise ArgumentError, "#{slug}: invalid link URL"
    end

    def validate_documents
      format = Disclosures::Document::PUBLIC_ID
      return if documents.all? { |id| id.is_a?(String) && id.match?(format) }

      raise ArgumentError, "#{slug}: documents must be public ids"
    end

    def validate_slugs
      slugs = questions.map(&:slug).compact_blank
      bad = slugs.find { |each| !each.match?(SLUG) || RESERVED.include?(each) }
      raise ArgumentError, "#{slug}: question slug #{bad} isn't allowed" if bad

      twice = slug_used_twice
      raise ArgumentError, "#{slug}: two questions use the slug #{twice}" if
        twice
    end

    def slug_used_twice
      questions.group_by(&:slug).find do |_, group|
        nations = group.flat_map do |question|
          question.nations.presence || NATIONS.keys
        end
        nations.size > nations.uniq.size
      end&.first
    end

    def rows(data, key, struct)
      data.fetch(key, []).map { |row| struct.new(**row.symbolize_keys) }
    end
  end
end
