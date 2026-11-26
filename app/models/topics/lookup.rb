module Topics
  # "Who holds it" for a search: the holders whose "what" names a word of the
  # query (potholes -> "local roads, potholes, street lights"), most words
  # matched first, from the topic files.
  module Lookup
    STOPWORDS = %w[
      the and for how many what who where when which with from about data
      information number numbers list figures records council councils
    ].freeze

    module_function

    def words(query)
      query.to_s.downcase.scan(/[[:alpha:]]+/).
        select { |word| word.length > 2 }.uniq - STOPWORDS
    end

    def holders(query, nation: 'england', limit: 2)
      patterns = words(query).map do |word|
        /\b#{Regexp.escape(word.singularize)}/i
      end
      return [] if patterns.empty?

      scored =
        Topic.holder_pairs.
        select { |holder, _| holder.for?(nation) }.
        map do |pair|
          [pair, patterns.count { |pattern| pair.first.what.match?(pattern) }]
        end
      scored.
        select { |_, score| score.positive? }.
        sort_by.with_index { |(_, score), index| [-score, index] }.
        map(&:first).uniq { |holder, _| holder.who }.first(limit)
    end
  end
end
