module Topics
  # Combines a Topic with one nation to resolve questions, holders, and routes.
  class Guide
    Entry = Struct.new(:question, :state, :url, :dataset, :holder,
                       keyword_init: true) do
      delegate :slug, to: :question

      def ask?
        question.ask.present?
      end

      def search_words
        question.keywords&.first || question.text
      end

      def ask_to
        named = holder&.to
        named && (named['body'] || named['wdtk']) ? named : question.ask
      end
    end

    OWN = /\b(your own|a relative|your records|subject access)\b/i

    attr_reader :topic, :nation

    def initialize(topic, nation)
      @topic = topic
      @nation = nation
    end

    def entries
      @entries ||=
        topic.questions.select { |question| question.useful_for?(nation) }.
        map { |question| build_entry(question) }
    end

    def entry(slug)
      entries.find { |entry| entry.slug == slug }
    end

    def look_up
      entries.select(&:url)
    end

    def ask_for
      entries.reject(&:url)
    end

    def holders
      @holders ||= topic.holders.select { |holder| holder.for?(nation) }
    end

    def published
      linked = entries.filter_map(&:url)
      topic.published.select do |item|
        item.for?(nation) && !linked.include?(item.url)
      end
    end

    def own
      routes.select { |row| own?(row) }
    end

    def instead
      routes.reject { |row| own?(row) || foi?(row) }
    end

    def elsewhere
      routes.select { |row| foi?(row) }
    end

    def warnings
      topic.refused - topic.questions.map(&:warning)
    end

    def logs
      topic.published.select do |item|
        item.for?(nation) && item.label.match?(/disclosure log/i)
      end
    end

    private

    def routes
      @routes ||= topic.elsewhere.select { |row| row.for?(nation) }
    end

    def own?(row)
      [row.what, row.route].join(' ').match?(OWN)
    end

    def foi?(row)
      row.to&.key?('wdtk')
    end

    def build_entry(question)
      url = question.published_url(nation)
      state = if url.nil? then :ask
              elsif question.partial && question.ask then :partial
              else :published
              end
      Entry.new(question: question, state: state, url: url,
                dataset: question.dataset_for(nation),
                holder: holder_for(question))
    end

    def holder_for(question)
      return unless (ask = question.ask)

      wanted = question.holder
      wanted = wanted[nation] if wanted.is_a?(Hash)
      if wanted
        named = holders.find { |holder|
  [holder.key, holder.who].include?(wanted)
}
        return named if named
      end
      matches = holders_answering(ask)
      matches.first if matches.map(&:who).uniq.one?
    end

    def holders_answering(ask)
      holders.select do |holder|
        holder.to && ask.any? { |key, value| holder.to[key] == value }
      end
    end
  end
end
