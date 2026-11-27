# Public facade for PostgreSQL full-text and authority typeahead search
# (see doc/FORK.md).
module Search
  def self.backend
    @backend ||= Adapters::Postgresql::Adapter.new
  end

  # Search scoped to a relation - returns a chainable ActiveRecord::Relation
  def self.search_scope(query, relation, **options)
    backend.search_scope(query, relation, **options)
  end

  # Typeahead search - returns a searchable object
  def self.typeahead(query, model:, **options)
    backend.typeahead(query, model: model, **options)
  end
end
