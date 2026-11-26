# Selects legacy or indexed search and measures the paginated query.
module Admin::Searchable
  extend ActiveSupport::Concern

  included do
    helper_method :search_engine, :legacy_search?, :search_stats
  end

  attr_reader :search_stats

  def search_engine
    @search_engine ||= params[:search_engine] == 'legacy' ? 'legacy' : 'new'
  end

  def legacy_search?
    search_engine == 'legacy'
  end

  # Browsing without a query has no relevance ranking.
  def indexed_search?
    params[:query].present? && !legacy_search?
  end

  # Returns the loaded relation and records its timings in search_stats.
  def measure_search(relation)
    @search_stats = Search::Stats.measure(relation)
    relation
  end
end
