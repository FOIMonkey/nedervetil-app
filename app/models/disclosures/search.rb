module Disclosures
  # Searches listed disclosure documents and their indexed public pages.
  class Search
    PER_PAGE = 20
    HITS_PER_DOCUMENT = 3
    START_MARK = "\u0002".freeze
    STOP_MARK = "\u0003".freeze
    HEADLINE = %(StartSel="#{START_MARK}", StopSel="#{STOP_MARK}", ) \
               'MaxWords=28, MinWords=12, ' +
               %(MaxFragments=2, FragmentDelimiter=" … ")
    FILTERS = %i[kind topic group sector body year file_type].freeze
    FILTER_TITLES = {
      kind: N_('Type'), topic: N_('Topic'), group: N_('Place or type'),
      sector: N_('Sector'), body: N_('Authority'), year: N_('Year'),
      file_type: N_('Format')
    }.freeze
    SIDE_FACETS = %i[topic group body year].freeze
    GROUP_HEADINGS = %w[place type].freeze
    SORTS = %w[released date].freeze
    FACET_LIMIT = 30
    BODY_FACET_LIMIT = 15
    PAGE_SCORED = 500
    DATE_SQL = 'COALESCE(disclosure_documents.document_date, ' \
               'disclosure_documents.released_on)'.freeze
    RELEASED_SQL = 'COALESCE(disclosure_documents.released_on, ' \
                   'disclosure_documents.document_date)'.freeze

    Hit = Struct.new(:number, :label, :kind, :snippet, keyword_init: true) do
      def anchor
        kind == 'sheet' ? "sheet-#{number}" : "page-#{number}"
      end
    end

    Group = Struct.new(:batch, :documents) do
      def batch?
        batch.present? && documents.size > 1
      end

      def several?
        documents.size > 1
      end

      def authorities
        documents.map(&:public_body_id).uniq.size
      end
    end

    attr_reader :query, :filters, :page, :sort

    def initialize(params)
      params = params.to_h.with_indifferent_access
      @query = params[:q].to_s.strip.first(200)
      @filters = FILTERS.
        index_with { |key| params[key].to_s.strip.presence }.compact
      @filters.delete(:kind) unless KINDS.include?(@filters[:kind])
      unless Document::FORMATS.include?(@filters[:file_type])
        @filters.delete(:file_type)
      end
      @filters.delete(:year) unless @filters[:year].to_s.match?(/\A\d{4}\z/)
      @filters.delete(:topic) if @filters[:topic] && !topic
      if @filters[:group] && !nation?(@filters[:group]) &&
         !group_titles.key?(@filters[:group])
        @filters.delete(:group)
      end
      @page = params[:page].to_i.clamp(1, 10_000)
      @sort = SORTS.include?(params[:sort]) ? params[:sort] : SORTS.first
    end

    def query?
      query.present?
    end

    def filtered?
      query? || filters.any?
    end

    def total
      @total ||= if !filters.key?(:kind) && @facets&.key?(:kind)
                   kind_total
                 else
                   scope.count
                 end
    end

    def groups
      @groups ||= begin
        documents = documents_for_page do |relation|
          relation.preload({ public_body: :translations },
                           { thumbnail_attachment: :blob },
                           :foi_attachment)
        end
        if query?
          documents.map { |document| Group.new(nil, [document]) }
        else
          documents.group_by { |document| release_key(document) }.values.
            flat_map do |same|
              bodies = same.map(&:public_body_id).uniq
              if bodies.size > 1
                [Group.new(nil, same)]
              else
                same.map { |document| Group.new(nil, [document]) }
              end
            end
        end
      end
    end

    def sheet_previews
      @sheet_previews ||= self.class.sheet_previews(results)
    end

    def self.sheet_previews(documents)
      ids = documents.reject { |doc| doc.thumbnail.attached? }.map(&:id)
      return {} if ids.empty?

      Page.where(document_id: ids, number: 1, kind: 'sheet').
        pluck(:document_id, Arel.sql('left(text, 4000)')).to_h
    end

    def results
      groups.flat_map(&:documents)
    end

    def metadata_results
      @metadata_results ||= documents_for_page do |relation|
        relation.preload(public_body: :translations)
      end
    end

    def pages
      (total.to_f / PER_PAGE).ceil
    end

    def hits
      return {} unless query? && results.any?

      @hits ||= self.class.page_hits(
        Document.listed.where(id: results.map(&:id)).
          select('disclosure_documents.id'),
        "websearch_to_tsquery('english', :q)", query,
        limit: HITS_PER_DOCUMENT
      )
    end

    def self.page_hits(documents, tsquery, query, limit:)
      sql = <<~SQL.squish
        SELECT document_id, number, label, kind, left(body, 300) AS head,
               right(body, 300) AS tail,
               ts_headline('english', body, #{tsquery}, :headline) AS snippet
        FROM (
          SELECT p.document_id, p.number, p.label, p.kind,
                 regexp_replace(left(p.text, 50000), '(\\t| {2,})+', ' · ', 'g')
                   AS body,
                 row_number() OVER (
                   PARTITION BY p.document_id
                   ORDER BY ts_rank(p.search_vector, #{tsquery}) DESC, p.number
                 ) AS position
          FROM disclosure_pages p
          WHERE p.document_id IN (#{documents.to_sql})
            AND p.search_vector @@ #{tsquery}
        ) ranked WHERE position <= :limit ORDER BY document_id, position
      SQL
      rows = Page.connection.select_all(
        Page.sanitize_sql_array(
          [sql, { q: query, headline: HEADLINE, limit: limit }]
        )
      )
      hits = Hash.new { |hash, key| hash[key] = [] }
      rows.each_with_object(hits) do |row, by_document|
        snippet = highlight(clipped(row['snippet'], row['head'], row['tail']))
        by_document[row['document_id']] << Hit.new(
          number: row['number'], label: row['label'], kind: row['kind'],
          snippet: snippet
        )
      end
    end

    def self.clipped(snippet, head, tail)
      plain = snippet.to_s.delete(START_MARK + STOP_MARK).squish
      return snippet if plain.empty?

      before = head.to_s.squish.start_with?(plain.first(30)) ? '' : '… '
      after = tail.to_s.squish.end_with?(plain.last(30)) ? '' : ' …'
      "#{before}#{snippet.to_s.strip}#{after}"
    end

    def self.highlight(snippet)
      # rubocop:disable Rails/OutputSafety -- the snippet is escaped first; only the search's own marks become <mark> tags
      ERB::Util.html_escape(snippet.to_s).to_str.
        gsub(START_MARK, '<mark>').gsub(STOP_MARK, '</mark>').html_safe
      # rubocop:enable Rails/OutputSafety
    end

    def facets
      FILTERS.index_with { |key| facet(key) }
    end

    def facet(key)
      @facets ||= {}
      @facets[key] ||=
        case key
        when :kind then kind_counts
        when :topic then topic_counts
        when :group then group_counts
        when :sector then sector_counts
        when :body then body_counts
        when :year then year_counts
        when :file_type then file_type_counts
        else []
        end
    end

    def kind_total
      facet(:kind).sum { |_, _, count| count }
    end

    def label_for(key, value)
      entry = facet(key).find { |candidate, _, _| candidate.to_s == value.to_s }
      return entry[1] if entry
      return topic.title if key == :topic && topic
      return group_titles[value] if key == :group && group_titles[value]
      if key == :group && defined?(Topics::Topic) && nation?(value)
        return _(Topics::Topic::NATIONS[value])
      end

      value
    end

    def title_for(key)
      _(FILTER_TITLES.fetch(key))
    end

    def shown_facets
      SIDE_FACETS.filter_map do |key|
        values = facet(key)
        if values.any?
          [key, values.first(key == :body ? BODY_FACET_LIMIT : FACET_LIMIT)]
        end
      end
    end

    private

    def entries
      @entries ||= ordered(scope).limit(PER_PAGE).offset((page - 1) * PER_PAGE).
        pluck('disclosure_documents.id').map { |id| [[id, nil]] }
    end

    def documents_for_page
      ids = entries.flatten(1).map(&:first)
      documents = yield(Document.listed.where(id: ids))
      documents.index_by(&:id).values_at(*ids).compact
    end

    def scope(except: nil)
      relation = Document.listed
      relation = relation.where(matches_sql, q: query) if query?
      filters.each do |key, value|
        next if key == except

        relation = apply(relation, key, value)
      end
      relation
    end

    def apply(relation, key, value)
      case key
      when :kind then relation.where(kind: value)
      when :file_type then relation.where(format: value)
      when :year
        relation.where("EXTRACT(YEAR FROM #{DATE_SQL}) = ?", value.to_i)
      when :body
        body = PublicBody.find_by_url_name(value)
        relation.where(public_body_id: body&.id || 0)
      when :topic
        relation.where(
          id: TopicMatch.where(topic: topic.slug).select(:document_id)
        )
      when :sector, :group
        tags = filter_tags(key, value)
        relation.where(<<~SQL.squish, tags)
          EXISTS (SELECT 1 FROM has_tag_string_tags sector_tags
                  WHERE sector_tags.model_type = 'PublicBody'
                    AND sector_tags.model_id = disclosure_documents.public_body_id
                    AND sector_tags.name IN (?))
        SQL
      else relation
      end
    end

    def filter_tags(key, value)
      if key == :group && nation?(value)
        Topics::Holds.nation_tags(value)
      else
        [value]
      end
    end

    def nation?(value)
      value != 'england' && Topics::Topic::NATIONS.key?(value)
    end

    def matches_sql
      <<~SQL.squish
        disclosure_documents.search_vector @@ websearch_to_tsquery('english', :q)
        OR EXISTS (SELECT 1 FROM disclosure_pages match_pages
                   WHERE match_pages.document_id = disclosure_documents.id
                     AND match_pages.search_vector @@ websearch_to_tsquery('english', :q))
      SQL
    end

    def ordered(relation)
      unless query?
        date = sort == 'date' ? DATE_SQL : RELEASED_SQL
        return relation.order(Arel.sql("#{date} DESC NULLS LAST"),
                              'disclosure_documents.published_at' => :desc,
                              'disclosure_documents.id' => :desc)
      end

      newest = "#{DATE_SQL} DESC NULLS LAST"
      details = Document.sanitize_sql_array(
        [
          "ts_rank(disclosure_documents.search_vector, " \
          "websearch_to_tsquery('english', :q))",
          { q: query }
        ]
      )
      pages = Document.sanitize_sql_array([<<~SQL.squish, { q: query }])
        COALESCE((SELECT max(ts_rank(rank_pages.search_vector, websearch_to_tsquery('english', :q)))
                  FROM disclosure_pages rank_pages
                  WHERE rank_pages.document_id = disclosure_documents.id
                    AND rank_pages.search_vector @@ websearch_to_tsquery('english', :q)), 0)
      SQL
      scored = relation.
        reorder(
          Arel.sql("#{details} DESC, #{newest}, disclosure_documents.id DESC")
        ).
        limit(PAGE_SCORED).select('disclosure_documents.id')
      rank = "#{details} + CASE WHEN disclosure_documents.id IN " \
             "(#{scored.to_sql}) THEN #{pages} ELSE 0 END"
      relation.order(Arel.sql("#{rank} DESC"), Arel.sql(newest),
                     'disclosure_documents.id' => :desc)
    end

    def counts(key, expression)
      scope(except: key).group(Arel.sql(expression)).count.
        sort_by { |value, count| [-count, value.to_s] }
    end

    def kind_counts
      counts(:kind, 'disclosure_documents.kind').map do |value, count|
        [value, _(Document::KIND_LABELS.fetch(value, value)), count]
      end
    end

    def year_counts
      counts(:year, "EXTRACT(YEAR FROM #{DATE_SQL})::int").
        reject { |value, _| value.nil? }.
        sort_by { |value, _| -value }.
        map { |value, count| [value.to_s, value.to_s, count] }
    end

    def file_type_counts
      counts(:file_type, 'disclosure_documents.format').
        map do |value, count|
          [value,
           _(Document::FORMAT_LABELS.fetch(value.to_s, 'Other')),
           count]
        end
    end

    def body_counts
      counted = scope(except: :body).
        group('disclosure_documents.public_body_id').count
      bodies = PublicBody.where(id: counted.keys).includes(:translations).
        index_by(&:id)
      rows = counted.filter_map do |id, count|
        body = bodies[id] or next
        [body.url_name, body.name, count]
      end
      rows.sort_by { |_, name, count| [-count, name] }
    end

    def sector_counts
      tag_counts(:sector, sector_categories)
    end

    def group_counts
      tag_counts(:group, group_titles)
    end

    def tag_counts(key, categories)
      return [] if categories.empty?

      counted = scope(except: key).
        joins(<<~SQL.squish).
          INNER JOIN has_tag_string_tags sector_tags
            ON sector_tags.model_type = 'PublicBody' AND sector_tags.model_id = disclosure_documents.public_body_id
        SQL
        where(sector_tags: { name: categories.keys }).
        group('sector_tags.name').distinct.count('disclosure_documents.id')
      counted.map { |tag, count| [tag, categories.fetch(tag), count] }.
        sort_by { |_, title, count| [-count, title] }
    end

    def group_titles
      return {} unless defined?(AuthorityGroups::Group)

      @group_titles ||= AuthorityGroups::Group.headings.
        slice(*GROUP_HEADINGS).values.
        flat_map { |heading| AuthorityGroups::Group.listing(heading).to_a }.
        to_h { |category| [category.category_tag, category.title] }
    end

    def topic_counts
      return [] unless defined?(Topics::Topic)

      topics = Topics::Topic.all.select(&:search)
      return [] if topics.empty?

      counted = TopicMatch.where(
        document_id: scope(except: :topic).select('disclosure_documents.id')
      ).group(:topic).count
      topics.filter_map do |candidate|
        count = counted[candidate.slug].to_i
        [candidate.slug, candidate.title, count] if count.positive?
      end
    end

    def topic
      return nil unless defined?(Topics::Topic)
      return @topic if defined?(@topic)

      found = filters[:topic] && Topics::Topic.find(filters[:topic])
      @topic = found&.search ? found : nil
    end

    def release_key(document)
      [document.title.to_s.squish.downcase,
       document.kind,
       document.released_on]
    end

    def sector_categories
      root = Category.roots.find { |category| category.title == 'PublicBody' }
      return {} unless root

      groups = root.children.
        select { |heading| %w[Place Type].include?(heading.title) }.
        flat_map { |heading| heading.children.map(&:category_tag) }
      sectors = root.list.select do |category|
        category.category_tag.present? && category.category_tag != 'other'
      end
      sectors.
        reject { |category| groups.include?(category.category_tag) }.
        to_h { |category| [category.category_tag, category.title] }
    end
  end
end
