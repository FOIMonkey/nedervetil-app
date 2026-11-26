require 'spec_helper'

RSpec.describe 'Ordinary notification creation' do
  it 'keeps the existing notification model without additional delivery/audit tables' do
    expect(ActiveRecord::Base.connection.tables.grep(/incoming_attention_/)).
      to match_array(%w[incoming_attention_predictions
                        incoming_attention_opt_outs
                        incoming_attention_instant_emails])
    expect(Notification.column_names).
      not_to include('suppressed_at', 'delivery_key', 'ai_disposition')
  end

  it 'uses core notification creation with the feature disabled' do
    allow(IncomingAttention::Config).to receive(:enabled?).and_return(false)
    target = FactoryBot.create(:info_request, use_notifications: true)
    before_ids = target.user.notifications.pluck(:id)
    receive_incoming_mail(info_request: target)
    rows = target.user.notifications.where.not(id: before_ids)
    expect(rows.count).to eq(1)
    expect(rows.first.info_request_event.event_type).to eq('response')
    expect(rows.first.seen_at).to be_nil
    expect(IncomingAttention::Prediction.where(info_request_id: target.id)).
      not_to exist
  end
end
