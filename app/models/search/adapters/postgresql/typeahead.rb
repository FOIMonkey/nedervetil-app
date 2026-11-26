module Search
  module Adapters
    module Postgresql
      # Authority typeahead using AuthorityQuery with a SimilarNameQuery
      # fallback (see doc/SEARCH.md).
      class Typeahead < Search::Adapter
        def initialize(query_string, exclude_tags: [])
          @exclude_tags = exclude_tags
          super(query_string, {})
        end

        def results(page: 1, per_page: 25)
          terms = prepared_terms
          return empty(page, per_page) if terms.empty?

          found = AuthorityQuery.new(terms.join(' | '),
                                     all_terms: terms.join(' & '),
                                     exclude_tags: @exclude_tags).
                  results(page: page, per_page: per_page)
          return found unless found.total_estimate.zero?

          SimilarNameQuery.new(text, exclude_tags: @exclude_tags).
            results(page: page, per_page: per_page)
        end

        private

        def text
          Searchable.without_apostrophes(query).
            truncate_bytes(252, omission: nil)
        end

        def prepared_terms
          words = text.split
          prefix = true
          if words.last && words.last.length < 3
            words.pop
            prefix = false
          end
          terms = words.map { _1.gsub(/[^[:alnum:]]/, '') }.reject(&:empty?)
          terms.map.with_index do |term, i|
            i == terms.size - 1 && prefix ? "'#{term}':*" : "'#{term}'"
          end
        end

        def empty(page, per_page)
          create_search_results(items: [], total_estimate: 0,
                                current_page: page, per_page: per_page)
        end
      end
    end
  end
end
