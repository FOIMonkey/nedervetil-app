require 'spec_helper'

RSpec.describe Search do
  let(:backend) { instance_double(Search::Adapters::Postgresql::Adapter) }

  before { allow(Search).to receive(:backend).and_return(backend) }

  describe '.backend' do
    it 'is the PostgreSQL adapter' do
      allow(Search).to receive(:backend).and_call_original
      expect(Search.backend).to be_a(Search::Adapters::Postgresql::Adapter)
    end
  end

  describe '.search_scope' do
    it 'delegates to the backend' do
      relation = User.all
      expect(backend).to receive(:search_scope).
        with('test', relation, admin_mode: true)
      Search.search_scope('test', relation, admin_mode: true)
    end
  end

  describe '.typeahead' do
    it 'delegates to the backend' do
      expect(backend).to receive(:typeahead).with(
        'test', model: PublicBody, exclude_tags: ['defunct']
      )
      Search.typeahead('test', model: PublicBody, exclude_tags: ['defunct'])
    end
  end
end
