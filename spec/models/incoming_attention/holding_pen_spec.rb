require 'spec_helper'
RSpec.describe 'Holding-pen administrator alerts' do
  before do
    ActionMailer::Base.deliveries.clear
    # Separate real advisory-lock tests cover concurrency; these examples run
    # inside RSpec's database transaction and all mail is intercepted.
    allow(IncomingAttention::Digest).to receive(:with_account_lock).and_yield
    allow(IncomingAttention::Config).to receive(:enabled?).and_return(false)
    allow(IncomingAttention::Job).
      to receive(:perform_later).and_return(double('queued'))
    expect(IncomingAttention::Client).not_to receive(:new)
  end
  [false, true].each do |enabled|
    it "delivers unroutable mail immediately without AI or digest enrollment, flag #{enabled}" do
      allow(IncomingAttention::Config).to receive(:enabled?).and_return(enabled)
      holding = InfoRequest.holding_pen_request
      expect(holding.use_notifications?).to be false
      receive_incoming_mail('incoming-request-plain.eml',
                            to: 'unknown-review@example.invalid')
      expect(ActionMailer::Base.deliveries.size).to eq(1)
      expect(ActionMailer::Base.deliveries.first.to).
        to eq([AlaveteliConfiguration.contact_email])
      expect(holding.user.notifications).to be_empty
      expect(IncomingAttention::Prediction.where(info_request_id: holding.id)).
        not_to exist
      expect(holding.reload.prominence).to eq('hidden')
      expect(holding.user.active_admin?).to be false
    end
    it "repairs queued old holding-pen alerts without blocking another user's digest, flag #{enabled}" do
      holding = InfoRequest.holding_pen_request
      holding.update_column(:use_notifications, true)
      mail = get_fixture_mail('incoming-request-plain.eml')
      message = holding.send(:create_response!, mail)
      old_notice = FactoryBot.create(:notification,
                                     user: holding.user,
                                     info_request_event: message.response_event,
                                     frequency: :daily,
                                     send_after: 1.minute.ago)
      expect(InfoRequest.holding_pen_request.use_notifications?).to be false
      other = FactoryBot.create(:info_request)
      receive_incoming_mail(info_request: other)
      other.user.notifications.update_all(send_after: 1.minute.ago)
      allow(IncomingAttention::Config).to receive(:enabled?).and_return(enabled)
      expect(NotificationMailer.send_daily_notifications).to be true
      expect(ActionMailer::Base.deliveries.size).to eq(2)
      expect(old_notice.reload.seen_at).to be_present
      expect(other.user.notifications.unseen).not_to exist
      expect(NotificationMailer.send_daily_notifications).to be false
    end
  end
  it 'retains an unsuccessful admin alert but continues ordinary daily mail' do
    holding = InfoRequest.holding_pen_request
    message = holding.send(:create_response!,
                           get_fixture_mail('incoming-request-plain.eml'))
    notice = FactoryBot.create(:notification,
                               user: holding.user,
                               info_request_event: message.response_event,
                               frequency: :daily)
    ordinary = FactoryBot.create(:info_request)
    receive_incoming_mail(info_request: ordinary)
    ordinary.user.notifications.update_all(send_after: 1.minute.ago)
    allow(RequestMailer).
      to receive(:new_response).and_raise('Synthetic delivery failure')
    allow(Rails.logger).to receive(:warn).and_call_original
    expect(NotificationMailer.send_daily_notifications).to be true
    expect(Rails.logger).to have_received(:warn).
      with('incoming_attention_holding_pen_alert_failed ' \
           "notification_id=#{notice.id} RuntimeError")
    expect(notice.reload.seen_at).to be_nil
    expect(ActionMailer::Base.deliveries.size).to eq(1)
    expect(ordinary.user.notifications.unseen).not_to exist
  end
  it 'does not use the administrative exception for a different hidden request or recipient' do
    target = FactoryBot.create(:info_request, prominence: 'hidden')
    target.update_column(:url_title, 'holding_pen')
    message = FactoryBot.create(:incoming_message, info_request: target)
    event = FactoryBot.create(:response_event, info_request: target,
                                               incoming_message: message)
    notice = FactoryBot.create(:notification, info_request_event: event,
                                              user: target.user)
    expect(NotificationMailer.send_daily_notifications).to be false
    expect(notice.reload.seen_at).to be_nil
    expect(ActionMailer::Base.deliveries).to be_empty
  end
end
