module Search
  module Adapters
    module Postgresql
      ##
      # The typeahead's fallback when full text finds nothing, as for a
      # misspelling ("Liverpol", "Mancester"): default-locale names that a
      # word in the query is like, by pg_trgm word similarity.
      class SimilarNameQuery < AuthorityQuery
        def initialize(text, exclude_tags: [])
          super(text, all_terms: nil, exclude_tags: exclude_tags)
        end

        private

        def where_sql
          sql = +'t.locale = :default_locale AND :tsq <% t.name'
          sql << " AND #{not_excluded('t.public_body_id')}" if excluding?
          sql
        end

        def select_rows(limit, offset)
          select_all(<<~SQL.squish)
            SELECT t.public_body_id AS id, word_similarity(:tsq, t.name) AS rank
            FROM public_body_translations t
            WHERE #{where_sql}
            ORDER BY rank DESC, length(t.name), t.public_body_id
            LIMIT #{Integer(limit)} OFFSET #{Integer(offset)}
          SQL
        end

        def count
          select_value('SELECT count(*) FROM public_body_translations t ' \
                       "WHERE #{where_sql}").to_i
        end
      end
    end
  end
end
