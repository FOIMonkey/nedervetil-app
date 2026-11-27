module Search
  module Adapters
    module Postgresql
      # PostgreSQL search backend behind Search (see doc/FORK.md).
      class Adapter
        def typeahead(query, model:, exclude_tags: [])
          unless model == PublicBody
            raise ArgumentError, "No typeahead for #{model}"
          end

          Typeahead.new(query, exclude_tags: exclude_tags)
        end

        # Full-text search constrained to +relation+, returning the joined
        # ActiveRecord::Relation directly so callers can compose further
        # conditions and ordering.
        def search_scope(query, relation, admin_mode: false, exact_mode: false,
                         case_sensitive: true, language: nil, limit: 1000)
          SearchDocument.hybrid_search(
            query,
            relation: relation,
            admin_mode: admin_mode,
            exact_mode: exact_mode,
            case_sensitive: case_sensitive,
            language: language,
            limit: limit
          )
        end
      end
    end
  end
end
