module Topics
  # Suggests published topic links and documents for draft request text using
  # PostgreSQL English stemming. Nothing is stored or counted.
  module Suggestions
    LIMIT = 3
    MAX_TEXT = 10_000
    COMMON = 'please provide information request freedom act copy details ' \
             'number total figures data records held hold including ' \
             'regarding relating following year month week date period last ' \
             'current recent many much council authority public body report ' \
             'document list response foi eir environmental regulations'.freeze
    HITS = 'SELECT count(*) FROM unnest(disclosure_documents.search_vector) ' \
           'AS v WHERE v.lexeme = ANY(ARRAY[:words]::text[])'.freeze
    TITLE_HITS = "(#{HITS} AND 'A' = ANY(v.weights))".freeze
    SCORE = "(#{TITLE_HITS} + (#{HITS}))".freeze
    # Counting questions only match when the letter asks for a quantity in the
    # same or next sentence (tables don't answer policy/minutes requests).
    COUNTING = /\AHow (many|much|long|often|full|punctual|bad)\b/
    # rubocop:disable Layout/LineLength
    QUANTITY = /\b(how\s(many|much|long|often)|numbers?\sof|total|figures?|statistics|stats|rates?|percentage|
                  proportion|average|count|spen[dt]|spending|cost|expenditure|waiting\stimes?|breakdown|annual(ly)?|
                  each\syear|per\s(year|month))\b/ix
    # rubocop:enable Layout/LineLength
    SENTENCE = /[.?!;]+\s|\n+|\s(?=\d+[.)]\s)|\s(?=[a-z][.)]\s)/

    Link = Struct.new(:title, :url, :note, :partial, keyword_init: true)

    module_function

    def questions(body, text, limit: LIMIT, subject: false)
      nation = body ? Holds.nation(body) : 'england'
      candidates = candidates(body, nation)
      phrases = candidates.each_with_index.flat_map do |question, index|
        question.keywords.map { |phrase| [index, phrase] }
      end
      return [] if phrases.empty? || text.blank?

      # Postgres reads "A&E" as the single letter "e".
      text = text.first(MAX_TEXT).gsub(/\bA ?& ?E\b/i, 'accident and emergency')
      found = {}
      matched([text, *quantity_windows(text)],
              phrases.map(&:last)).each do |window, position, words|
        index = phrases[position].first
        counting = !subject && COUNTING.match?(candidates[index].text)
        if counting ? window.positive? : window.zero?
          found[position] = [index, words]
        end
      end
      scores =
        found.values.each_with_object(Hash.new(0)) do |(index, words), sum|
          sum[index] += words
        end
      scores.sort_by { |index, score| [-score, index] }.first(limit).
        map { |index, _| link(candidates[index], body, nation) }
    end

    HOLDERS = { 'local_council' => N_('Councils'),
                'police' => N_('Police forces'),
                'fire_service' => N_('Fire and rescue services'),
                'nhs_trust' => N_('NHS trusts'),
                'icb' => N_('Integrated care boards'),
                'hsc_trust' => N_('Health and social care trusts'),
                'health_board' => N_('Health boards') }.freeze

    def usually(ask)
      return unless ask

      if ask['body']
        ["#{ask['body']} usually holds this.", 'Search for it.']
      elsif (label = HOLDERS[ask['tag']])
        ["#{label} usually hold this.", 'Search for yours.']
      end
    end

    # Adjacent sentence/list-item pairs asking for a quantity; bare markers
    # ("1.", "b)") are dropped so numbered items stay adjacent.
    def quantity_windows(text)
      parts = text.split(SENTENCE).map(&:strip).reject do |part|
        part.match?(/\A(\d{1,2}|[a-z])?[.)]?\z/i)
      end
      (parts.each_cons(2).map { |pair| pair.join(' ') } + parts.last(1)).
        select { |window| window.match?(QUANTITY) }
    end

    # Matches documents with >=2 title hits or 1 title + 2 body hits.
    def documents(body, text, limit: LIMIT)
      words = words(text, body)
      return [] if words.empty?

      query = words.
              map { |word| "'#{word.gsub(/['\\]/) { |char| char * 2 }}'" }.
              join(' | ')
      order = Disclosures::Document.sanitize_sql_array(
        ["#{SCORE} DESC, disclosure_documents.public_body_id = :body DESC, " \
         "#{Disclosures::Search::RELEASED_SQL} DESC NULLS LAST",
         { words: words, body: body&.id }]
      )
      ids = Disclosures::Document.listed.
            where("disclosure_documents.search_vector @@ :query::tsquery " \
                  "AND #{TITLE_HITS} >= 1 AND #{SCORE} >= 4",
                  query: query, words: words).
            order(Arel.sql(order), 'disclosure_documents.id' => :desc).
            limit(limit * 4).pluck(:id)
      found = Disclosures::Document.listed.where(id: ids).
              preload(public_body: :translations).
              index_by(&:id)
      found.values_at(*ids).compact.map(&:public_view).
        uniq { |document| document.title.to_s.squish.downcase }.first(limit)
    end

    # Also matches holders linked via `to: { tag: }`, since Holds only checks
    # holders' `groups`.
    def candidates(body, nation)
      held = body ? Holds.held(body).map { |_, topic| topic.slug } : []
      pairs = Topic.all.flat_map do |topic|
        topic.questions.map { |question| [question, topic] }
      end
      pairs.filter_map do |question, topic|
        next unless suggestable?(question, nation)
        next question unless body

        fits = fits_body?(question, topic, body, nation, held)
        question if fits
      end
    end

    def suggestable?(question, nation)
      question.keywords.present? && question.for?(nation) &&
        question.published_for?(nation)
    end

    def fits_body?(question, topic, body, nation, held)
      if question.ask
        fits?(question.ask, body)
      else
        held.include?(topic.slug) ||
          topic.holders.any? do |holder|
            holder.for?(nation) && fits?(holder.to, body)
          end
      end
    end

    def fits?(to, body)
      to.present? &&
        (to['body'] == body.name ||
         (to['tag'].present? && body.has_tag?(to['tag'])))
    end

    # Returns [text_index, phrase_index, word_count] for stemmed phrase matches
    # (ordered phrase matching avoids false positives from loose word order).
    def matched(texts, phrases)
      sql = ActiveRecord::Base.sanitize_sql_array(
        [<<~SQL.squish, { texts: texts, phrases: phrases }]
          WITH t AS MATERIALIZED (
            SELECT t.n, to_tsvector('english', t.body) AS vector
            FROM unnest(ARRAY[:texts]::text[]) WITH ORDINALITY AS t(body, n)
          )
          SELECT t.n, k.position, array_length(tsvector_to_array(to_tsvector('english', k.phrase)), 1)
          FROM t, unnest(ARRAY[:phrases]::text[]) WITH ORDINALITY AS k(phrase, position)
          WHERE t.vector @@ phraseto_tsquery('english', k.phrase)
        SQL
      )
      ActiveRecord::Base.connection.select_rows(sql).map do |n, position, words|
        [n.to_i - 1, position.to_i - 1, words.to_i]
      end
    end

    def words(text, body)
      binds = { text: text.to_s.first(MAX_TEXT),
                common: "#{COMMON} #{body&.name}" }
      sql = ActiveRecord::Base.sanitize_sql_array([<<~SQL.squish, binds])
        SELECT lexeme FROM unnest(to_tsvector('english', :text))
        WHERE length(lexeme) > 1 AND lexeme !~ '^[0-9]+$'
          AND lexeme <> ALL (tsvector_to_array(to_tsvector('english', :common)))
      SQL
      ActiveRecord::Base.connection.select_values(sql)
    end

    def link(question, body, nation)
      dataset = question.dataset_for(nation)
      url = if dataset
              (body ? dataset.url_for(body) : dataset.url)
            else
              question.published_url(nation)
            end
      note = if dataset
               "#{dataset.title} · #{dataset.publisher}"
             else
               URI(url).host.to_s.delete_prefix('www.')
             end
      Link.new(title: question.text, url: url, note: note,
               partial: question.partial)
    end
  end
end
