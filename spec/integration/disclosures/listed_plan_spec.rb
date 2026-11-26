require 'spec_helper'

# Document.listed keeps its integrity checks as one condition: as separate
# clauses, PostgreSQL estimates one row for every listing, and so it joins and
# sorts the whole catalogue.
RSpec.describe 'Listed documents query plans' do
  include PublicationFeedHelpers
  include_context 'with document OCR off'
  include_context 'with production error pages'

  let!(:document) { make_feed_document }
  let(:connection) { ActiveRecord::Base.connection }

  def estimated_rows(relation)
    plan = connection.select_value("EXPLAIN (FORMAT JSON) #{relation.to_sql}")
    plan = JSON.parse(plan) if plan.is_a?(String)
    plan.first.dig('Plan', 'Plan Rows')
  end

  def statements
    queries = []
    callback = ->(*, payload) do
      unless payload[:cached] || %w[SCHEMA TRANSACTION].include?(payload[:name])
        queries << payload[:sql]
      end
    end
    ActiveSupport::Notifications.subscribed(callback, 'sql.active_record') do
      yield
    end
    queries
  end

  def spread_over_bodies(base, count)
    bodies = Array.new(count) { FactoryBot.create(:public_body) }
    Disclosures::Document.where('id > ?', base).
      order(:id).each_with_index do |record, index|
        record.update_columns(public_body_id: bodies[index % count].id)
      end
  end

  it 'estimates the listing and the home page’s first page from their join keys, not as one row' do
    expand_catalogue(document, 40)
    %w[disclosure_documents info_requests incoming_messages
       foi_attachments].each do |table|
      connection.execute("ANALYZE #{table}")
    end
    search = Disclosures::Search.new({})
    home = search.send(:ordered, search.send(:scope)).
      limit(Disclosures::Search::PER_PAGE).select('disclosure_documents.id')

    expect(Disclosures::Document.listed.count).to eq(41)
    expect(estimated_rows(Disclosures::Document.listed)).to be > 1
    expect(estimated_rows(home)).to be > 1
  end

  it 'keeps the home page to the same statements however many documents and authorities are listed' do
    get '/'
    few = statements { get '/' }
    expect(response).to have_http_status(:ok)
    spread_over_bodies(expand_catalogue(document, 30), 8)
    many = statements { get '/' }
    expect(response).to have_http_status(:ok)
    expect(response.body).to include('Published catalogue ledger')
    expect(many.size).to eq(few.size)
    # The process keeps the topic content it built, and a page asks only
    # whether its version has moved.
    expect(many.grep(/"topic_/)).
      to contain_exactly(a_string_matching(/MAX\("topic_changes"\."id"\)/))
    # The layout's links decide how many feature flags it reads; the cap is
    # on the rest.
    expect(many.grep_v(/"flipper_gates"|"topic_/).size).to be <= 9
  end
end
