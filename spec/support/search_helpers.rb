# Typeahead stubs; include SearchHelpers, then call
# stub_typeahead_results(items: [...]). A spec tagged :search_index searches
# the real index instead; its authorities are indexed first, because fixtures
# skip the callbacks that write their search documents.
module SearchHelpers
  # Empty backend results without accessing an index.
  class NullSearcher
    def results(page: 1, per_page: 25)
      Search::Results.new(
        items: [],
        total_estimate: 0,
        current_page: page,
        per_page: per_page,
        offset: (page - 1) * per_page
      )
    end

    def first(_limit = 10)
      [[], false]
    end
  end

  # Prevent index access while this thread's search stubs are enabled.
  module Guard
    def typeahead(query, model:, **options)
      SearchHelpers.stubbed? ? SearchHelpers::NullSearcher.new : super
    end
  end

  def self.stubbed?
    Thread.current[:search_helpers_stubbed]
  end

  def self.stubbed=(value)
    Thread.current[:search_helpers_stubbed] = value
  end

  # Stub Search.typeahead to return a Results object with the given items
  def stub_typeahead_results(items: [], total: nil, spelling_correction: nil,
                             words_to_highlight: [])
    total ||= items.size
    results = build_search_results(
      items: items,
      total: total,
      spelling_correction: spelling_correction,
      words_to_highlight: words_to_highlight
    )

    searcher = double('Typeahead', results: results)
    allow(Search).to receive(:typeahead).and_return(searcher)
    allow(Search.backend).to receive(:typeahead).and_return(searcher)
    results
  end

  # Build a Search::Results object with the given attributes
  def build_search_results(items: [], total: nil, page: 1, per_page: 25,
                           spelling_correction: nil, words_to_highlight: [],
                           has_normal_search_terms: false)
    total ||= items.size
    offset = (page - 1) * per_page

    # Convert items to the format expected by views (hash with :model key)
    # if they're not already in that format
    formatted_items = items.map do |item|
      if item.is_a?(Hash) && item.key?(:model)
        item
      else
        { model: item, percent: 100, weight: 1.0, collapse_count: 0 }
      end
    end

    Search::Results.new(
      items: formatted_items,
      total_estimate: total,
      current_page: page,
      per_page: per_page,
      offset: offset,
      spelling_correction: spelling_correction,
      words_to_highlight: words_to_highlight,
      has_normal_search_terms: has_normal_search_terms
    )
  end

  # Stub an empty typeahead result
  def stub_empty_typeahead_results
    stub_typeahead_results(items: [], total: 0)
  end
end

Search::Adapters::Postgresql::Adapter.prepend(SearchHelpers::Guard)

RSpec.configure do |config|
  config.include SearchHelpers

  config.around(:each) do |example|
    SearchHelpers.stubbed = true unless example.metadata[:search_index]
    example.run
  ensure
    SearchHelpers.stubbed = false
  end

  config.before(:each, search_index: true) do
    PublicBody.find_each(&:reindex)
  end
end
