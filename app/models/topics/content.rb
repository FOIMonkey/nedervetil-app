module Topics
  # Deeply frozen snapshot of topics and datasets keyed by TopicChange's max id,
  # shared across threads in a process.
  class Content
    # Process-wide snapshot cache; rebuilds on version mismatch (not just newer,
    # since rolled-back transactions can move the version backwards).
    class Cache
      def initialize
        @lock = Mutex.new
        @content = nil
      end

      def fetch(version)
        content = @content
        return content if content&.at?(version)

        @lock.synchronize do
          @content = Content.build unless @content&.at?(version)
          @content
        end
      end
    end

    # Constant on Content so code reloading discards stale Topic instances.
    CACHE = Cache.new

    attr_reader :version, :topics, :datasets

    class << self
      def current
        Current.topic_content ||= CACHE.fetch(version)
      end

      # Retries uncached if version changes mid-build so rows never mix versions
      # and Rails's query cache can't serve stale rows on retry.
      def build
        ActiveRecord::Base.uncached do
          loop do
            before = version
            content = new(before, TopicPage.topics, TopicDataset.datasets)
            return content if version == before
          end
        end
      end

      def version
        ActiveRecord::Base.uncached { TopicChange.maximum(:id) }
      end
    end

    def initialize(version, topics, datasets)
      @version = version
      @topics = topics
      @datasets = datasets.index_by(&:id)
      Ractor.make_shareable(self)
    end

    def at?(version)
      self.version == version
    end
  end
end
