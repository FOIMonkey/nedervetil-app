require 'spec_helper'

RSpec.describe 'Indexes for the signed-in pages' do
  def index(table, name)
    ActiveRecord::Base.connection.indexes(table).
      find { |found| found.name == name }
  end

  it 'finds automatic classifications and the outcome checks still to run without reading every prediction' do
    expect(index(:incoming_attention_predictions,
                 'incoming_attention_auto_classified_event')).
      to have_attributes(columns: ['response_event_id'],
                         where: 'auto_classified')
    sweep = index(:incoming_attention_predictions,
                  'incoming_attention_outcome_sweep')
    expect(sweep.columns).to eq(['outcome_checked_at'])
    expect(sweep.where).to include('outcome_status', 'pending', 'running')
  end

  it 'finds a user’s drafts by user' do
    expect(ActiveRecord::Base.connection.
             index_exists?(:draft_info_requests, :user_id)).to be(true)
  end
end
