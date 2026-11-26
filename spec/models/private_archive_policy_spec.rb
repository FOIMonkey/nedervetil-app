require 'spec_helper'

RSpec.describe 'PrivateArchive core policy overrides' do
  describe "a request's prominence" do
    it 'is requester_only from the start' do
      expect(FactoryBot.build(:info_request).prominence).
        to eq('requester_only')
    end

    it 'is requester_only or hidden, and nothing else' do
      %w[requester_only hidden].each do |prominence|
        expect(FactoryBot.build(:info_request, prominence: prominence)).
          to be_valid
      end
      ['normal', 'backpage', nil, 'invalid'].each do |prominence|
        expect(FactoryBot.build(:info_request, prominence: prominence)).
          not_to be_valid
      end
    end
  end

  describe 'admin field placement' do
    it 'keeps fields admin-only' do
      options = PrivateArchive::Policy.searchable_options(
        index: { body: 'A' }, admin_index: { prominence_reason: 'D' },
        root: :info_request, filterable: [:prominence],
        sortable: [:created_at]
      )
      expect(options).to eq(
        admin_index: { body: 'A', prominence_reason: 'D' },
        root: :info_request, filterable: [:prominence],
        sortable: [:created_at]
      )
    end
  end

  describe 'the complete public-to-admin search index moves' do
    # User and InfoRequestEvent were already admin-only upstream.
    {
      InfoRequest => {
        admin_index: { title: 'A', url_title: 'B', prominence_reason: 'D' }
      },
      OutgoingMessage => {
        admin_index: { '.get_text_for_indexing': 'A', '.safe_from_name': 'D',
                       from_name: 'B', prominence_reason: 'D' },
        root: :info_request
      }
    }.each do |model, options|
      it "keeps #{model} fields and weights exclusively in the admin index" do
        expect(model.search_options).to eq(options)
      end
    end
  end
end
