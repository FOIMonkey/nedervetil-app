##
# The chainable search_scope interface, exercised against real fixture data.
# Include it from an adapter spec with a `subject` that returns the adapter:
#
#   RSpec.describe Search::Adapters::Postgresql::Adapter, :postgresql do
#     subject(:adapter) { described_class.new }
#     it_behaves_like 'a scoped search backend'
#   end
RSpec.shared_examples 'a scoped search backend' do
  # Backends that only index some models privately (e.g. PostgreSQL indexes
  # users in the admin index) can supply the options needed to search them.
  let(:search_scope_options) { {} }

  describe '#search_scope' do
    it 'returns an ActiveRecord::Relation' do
      scope = adapter.search_scope('bob', User.all, **search_scope_options)
      expect(scope).to be_a(ActiveRecord::Relation)
    end

    it 'constrains the relation to matching records' do
      scope = adapter.search_scope('quango', PublicBody.all,
                                   **search_scope_options)
      expect(scope).to include(public_bodies(:geraldine_public_body))
    end

    it 'keeps the relation chainable with further conditions' do
      bob = users(:bob_smith_user)
      scope = adapter.search_scope('bob', User.all, **search_scope_options).
              where.not(id: bob.id)
      expect(scope).not_to include(bob)
    end

    it 'respects conditions already applied to the relation' do
      bob = users(:bob_smith_user)
      scope = adapter.search_scope(
        'bob', User.where.not(id: bob.id), **search_scope_options
      )
      expect(scope).not_to include(bob)
    end
  end
end
