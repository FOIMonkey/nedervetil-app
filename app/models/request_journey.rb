# Only an explicit subject check queries publications: no typeahead, counts,
# facets, thumbnails, external fetches or search/click history.
module RequestJourney
  # Signs a draft's recipient and text so edits require re-review without
  # exposing the private letter in the token or form.
  module Review
    module_function

    def fingerprint(draft)
      Digest::SHA256.hexdigest([draft.id, draft.user_id, draft.public_body_id,
                                draft.title, draft.body].to_json)
    end

    def token(draft)
      Rails.application.message_verifier(:request_review).
        generate(fingerprint(draft))
    end

    def valid?(draft, token)
      draft&.persisted? &&
        Rails.application.message_verifier(:request_review).
          verified(token.to_s) == fingerprint(draft)
    end
  end

  # The topic, nation and holder a request journey carries, kept only when
  # they match the topic files.
  class Context
    attr_reader :values

    def initialize(raw)
      raw = {} unless raw.is_a?(Hash) || raw.respond_to?(:permit)
      raw = if raw.respond_to?(:permit)
              raw.permit(:topic, :nation, :holder).to_h
            else
              raw.to_h
            end
      @values = {}
      return unless defined?(Topics::Topic)

      topic = Topics::Topic.find(raw_value(raw, 'topic'))
      @values['topic'] = topic.slug if topic
      nation = raw_value(raw, 'nation').to_s
      @values['nation'] = nation if Topics::Topic::NATIONS.key?(nation)
      holder = raw_value(raw, 'holder').to_s
      tags = holder_tags(topic)
      @values['holder'] = holder if tags.include?(holder)
    end

    def [](key)
      values[key]
    end

    private

    def raw_value(raw, key)
      raw[key] || raw[key.to_sym]
    end

    def holder_tags(topic)
      (topic ? [topic] : Topics::Topic.all).flat_map(&:questions).
        filter_map { |question| question.ask&.dig('tag') }
    end
  end

  # Public metadata only, with a single matching page from the published
  # version.
  class Suggestions
    LIMIT = 3
    Document = Struct.new(:public_id, :title, :released_on, :document_id, :hit,
                          keyword_init: true)
    attr_reader :body, :subject

    def initialize(body, subject)
      @body = body
      @subject = subject.to_s.first(200)
    end

    def questions
      @questions ||= if defined?(Topics::Suggestions)
                       Topics::Suggestions.questions(body, subject, subject: true)
                     else
                       []
                     end
    end

    def documents
      @documents ||=
        if query.blank?
          []
        else
          metadata = 'disclosure_documents.search_vector @@ :q::tsquery'
          match = "#{metadata} OR EXISTS (SELECT 1 FROM disclosure_pages p " \
                  'WHERE p.document_id = disclosure_documents.id ' \
                  'AND p.search_vector @@ :q::tsquery)'
          rank = Disclosures::Document.
            sanitize_sql_array(["(#{metadata}) DESC", { q: query }])
          rows = Disclosures::Document.listed.
                 where(public_body_id: body.id).
                 where(match, q: query).
                 order(Arel.sql(rank),
                       Arel.sql("#{Disclosures::Search::RELEASED_SQL} " \
                                'DESC NULLS LAST')).
                 order(id: :desc).limit(LIMIT).
                 pluck(:public_id, :title, :released_on, :id)
          hits = page_hits(rows.map(&:last))
          rows.map do |public_id, title, date, id|
            Document.new(public_id: public_id,
                         title: title,
                         released_on: date,
                         document_id: id,
                         hit: hits[id])
          end
        end
    end

    def releases
      @releases ||=
        if query.blank?
          []
        else
          AuthorityGroups::ExternalRelease.visible.
            where(public_body_id: body.id).
            where("to_tsvector('english', title) @@ ?::tsquery", query).
            newest_first.limit(LIMIT).
            select(:title, :url, :released_on).to_a
        end
    end

    def any?
      questions.any? || documents.any? || releases.any?
    end

    private

    # Require all non-boilerplate words (up to 12) to avoid weak matches.
    def query
      @query ||= begin
        words = if defined?(Topics::Suggestions)
                  Topics::Suggestions.words(subject, body)
                else
                  sql = ActiveRecord::Base.sanitize_sql_array([
                    "SELECT lexeme FROM unnest(to_tsvector('english', :text)) " \
                    "WHERE length(lexeme) > 1 AND lexeme !~ '^[0-9]+$'",
                    { text: subject.to_s.first(2_000) }
                  ])
                  ActiveRecord::Base.connection.select_values(sql)
                end
        words.first(12).
          map { |word| "'#{word.gsub(/['\\]/) { |char| char * 2 }}'" }.
          join(' & ')
      end
    end

    def page_hits(document_ids)
      return {} if document_ids.empty?

      public_documents = Disclosures::Document.listed.
        where(public_body_id: body.id, id: document_ids).
        select('disclosure_documents.id')
      Disclosures::Search.page_hits(public_documents, ':q::tsquery', query,
                                    limit: 1).transform_values(&:first)
    end
  end
end
