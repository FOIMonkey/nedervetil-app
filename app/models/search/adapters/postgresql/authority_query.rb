module Search
  module Adapters
    module Postgresql
      # Full-text PostgreSQL query for authority search over search_documents
      # (see doc/SEARCH.md).
      class AuthorityQuery < Search::Adapter
        # {D, C, B, A}: weight name/short_name (A) and notes (C) only.
        RANK_WEIGHTS = '{0, 0.2, 0, 1}'.freeze

        # tsquery_value is ORed terms; all_terms is the same terms ANDed.
        def initialize(tsquery_value, all_terms:, exclude_tags: [])
          @tsquery_value = tsquery_value
          @all_terms = all_terms
          @exclude_tags = Array(exclude_tags)
          super(tsquery_value, {})
        end

        def results(page: 1, per_page: 25)
          offset = calculate_offset(page, per_page)
          rows = select_rows(per_page, offset)
          bodies = PublicBody.includes(:translations, :tags).
                   where(id: rows.map { _1['id'] }).index_by(&:id)
          items = rows.filter_map do |row|
            body = bodies[row['id']]
            { model: body, weight: row['rank'].to_f } if body
          end
          create_search_results(items: items, total_estimate: count,
                                current_page: page, per_page: per_page,
                                offset: offset)
        end

        private

        def languages
          [AlaveteliLocalization.locale, AlaveteliLocalization.default_locale].
            map { Searchable.lang_from_locale(_1.to_s) }.uniq
        end

        def binds
          { tsq: @tsquery_value, all_terms: @all_terms.to_s,
            tags: @exclude_tags,
            default_locale: AlaveteliLocalization.default_locale.to_s }
        end

        # One constant tsquery per language, so the text index is used.
        def tsquery(language, value = ':tsq')
          "to_tsquery(#{quote(language)}::regconfig, unaccent(#{value}))"
        end

        def quote(value)
          SearchDocument.connection.quote(value)
        end

        def matches_sql
          languages.map do |language|
            "(sd.language = #{quote(language)} AND " \
              "sd.content_tsv @@ #{tsquery(language)})"
          end.join(' OR ')
        end

        # Rank all-term matches by term proximity; partial matches by :tsq.
        def rank_sql
          whens = languages.map do |language|
            all = tsquery(language, ':all_terms')
            "WHEN #{quote(language)} THEN CASE WHEN sd.content_tsv @@ #{all} " \
              "THEN #{rank(all)} ELSE #{rank(tsquery(language))} END"
          end
          "CASE sd.language #{whens.join(' ')} END"
        end

        def rank(tsquery)
          "ts_rank_cd('#{RANK_WEIGHTS}', sd.content_tsv, #{tsquery})"
        end

        def all_terms_sql
          whens = languages.map do |language|
            "WHEN #{quote(language)} THEN sd.content_tsv @@ " \
              "#{tsquery(language, ':all_terms')}"
          end
          "CASE sd.language #{whens.join(' ')} END"
        end

        def where_sql
          sql = +"sd.searchable_type = 'PublicBody' AND (#{matches_sql})"
          sql << " AND #{not_excluded('sd.searchable_id')}" if excluding?
          sql
        end

        def excluding?
          @exclude_tags.any?
        end

        def not_excluded(column)
          "#{column} NOT IN (SELECT model_id FROM has_tag_string_tags " \
            "WHERE model_type = 'PublicBody' AND name IN (:tags))"
        end

        def order_sql
          "bool_or(#{all_terms_sql}) DESC, rank DESC, min(length(t.name)), id"
        end

        def select_rows(limit, offset)
          sql = <<~SQL.squish
            SELECT sd.searchable_id AS id, max(#{rank_sql}) AS rank
            FROM search_documents sd
            JOIN public_bodies pb ON pb.id = sd.searchable_id
            JOIN public_body_translations t
              ON t.public_body_id = pb.id AND t.locale = :default_locale
            WHERE #{where_sql}
            GROUP BY sd.searchable_id
            ORDER BY #{order_sql}
            LIMIT #{Integer(limit)} OFFSET #{Integer(offset)}
          SQL
          select_all(sql)
        end

        def count
          select_value('SELECT count(DISTINCT sd.searchable_id) ' \
                       "FROM search_documents sd WHERE #{where_sql}").to_i
        end

        def select_value(sql)
          SearchDocument.connection.select_value(
            SearchDocument.sanitize_sql([sql, binds])
          )
        end

        def select_all(sql)
          SearchDocument.connection.select_all(
            SearchDocument.sanitize_sql([sql, binds])
          ).to_a
        end
      end
    end
  end
end
