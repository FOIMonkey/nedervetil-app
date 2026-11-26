require 'spec_helper'
require Rails.root.join(
  'db/migrate', '20261106120000_make_every_request_requester_only_or_hidden'
).to_s

# DDL is transactional in PostgreSQL, so each example's schema changes roll
# back with its transaction.
RSpec.describe MakeEveryRequestRequesterOnlyOrHidden do
  def migrate(direction)
    ActiveRecord::Migration.suppress_messages do
      described_class.migrate(direction)
    end
  end

  def column_default
    ActiveRecord::Base.connection.columns(:info_requests).
      find { |column| column.name == 'prominence' }.default
  end

  # Written directly, as validation refuses the public values.
  def request_at(prominence)
    FactoryBot.create(:info_request).tap do |request|
      request.update_columns(prominence: prominence)
    end
  end

  it 'makes a normal or backpage request requester_only' do
    migrate(:down)
    requests = %w[normal backpage requester_only hidden].
      index_with { request_at(_1) }

    migrate(:up)

    expect(requests.transform_values { _1.reload.prominence }).to eq(
      'normal' => 'requester_only', 'backpage' => 'requester_only',
      'requester_only' => 'requester_only', 'hidden' => 'hidden'
    )
  end

  it 'gives the column requester_only as its default, and puts normal back' do
    migrate(:down)
    expect(column_default).to eq('normal')

    migrate(:up)
    expect(column_default).to eq('requester_only')
  end

  it 'leaves the requests as they are on the way down' do
    request = request_at('normal')
    migrate(:down)
    migrate(:up)
    migrate(:down)
    expect(request.reload.prominence).to eq('requester_only')
  end
end
