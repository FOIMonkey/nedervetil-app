require 'spec_helper'

RSpec.describe 'Daily summary email' do
  # With incoming attention on, a reply's notification waits for its check;
  # these specs are about core's summary itself.
  include_context 'with incoming attention off'

  let(:user) { FactoryBot.create(:user, trusted: true) }

  before { ActionMailer::Base.deliveries.clear }

  describe 'which requests go into the summary' do
    it 'includes a request sent on its own' do
      info_request = FactoryBot.create(:info_request, user: user)
      expect(info_request.reload.use_notifications).to eq(true)
    end

    it 'includes every request in a batch' do
      batch = FactoryBot.create(:info_request_batch, :sent,
                                user: user, public_body_count: 2)
      expect(batch.info_requests.reload.map(&:use_notifications)).
        to eq([true, true])
    end

    it 'leaves a setting given explicitly alone' do
      info_request =
        FactoryBot.create(:info_request, user: user, use_notifications: false)
      expect(info_request.reload.use_notifications).to eq(false)
    end
  end

  it 'is daily for every account' do
    expect(user.notification_frequency).to eq(Notification::DAILY)
  end

  describe 'a new response' do
    let(:info_request) { FactoryBot.create(:info_request, user: user) }

    it 'is not emailed on its own' do
      receive_incoming_mail(info_request: info_request)
      expect(ActionMailer::Base.deliveries).to be_empty
    end

    it "waits for the account's next daily summary" do
      receive_incoming_mail(info_request: info_request)
      notification = user.notifications.last
      expect(notification).to be_daily
      expect(notification.info_request_event.event_type).to eq('response')
      expect(notification.send_after).
        to be_between(1.minute.ago, 1.day.from_now)
      expect([notification.send_after.hour, notification.send_after.min]).
        to eq([user.daily_summary_hour, user.daily_summary_minute])
    end
  end

  describe 'an overdue request' do
    let(:info_request) do
      travel_to(Time.zone.parse('2014-12-31')) do
        FactoryBot.create(:info_request, user: user)
      end
    end

    it 'goes into the summary instead of being emailed on its own' do
      info_request
      travel_to(Time.zone.parse('2015-01-30')) do
        InfoRequest.log_overdue_events
      end
      expect(ActionMailer::Base.deliveries.flat_map(&:to)).
        not_to include(user.email)
      expect(user.notifications.map { _1.info_request_event.event_type }).
        to eq(['overdue'])
    end
  end

  describe 'the summary' do
    def due_at
      user.notifications.maximum(:send_after)
    end

    def send_summaries_at(time)
      travel_to(time) { NotificationMailer.send_daily_notifications }
    end

    it 'covers single and batch requests in one email' do
      single = FactoryBot.create(:info_request, user: user)
      batch = FactoryBot.create(:info_request_batch, :sent,
                                user: user, public_body_count: 2)
      receive_incoming_mail(info_request: single)
      batch.info_requests.each { receive_incoming_mail(info_request: _1) }

      send_summaries_at(due_at + 1.minute)

      expect(ActionMailer::Base.deliveries.size).to eq(1)
      mail = ActionMailer::Base.deliveries.first
      expect(mail.to).to eq([user.email])
      expect(mail.subject).to eq('3 replies')
      body = mail.body.to_s
      expect(body).to include(single.title)
      expect(body).to include(batch.title)
      expect(body).to include('2 replies')
    end

    it "is not sent before the account's time" do
      receive_incoming_mail(
        info_request: FactoryBot.create(:info_request, user: user)
      )
      send_summaries_at(due_at - 1.minute)
      expect(ActionMailer::Base.deliveries).to be_empty
    end

    it 'is sent once' do
      receive_incoming_mail(
        info_request: FactoryBot.create(:info_request, user: user)
      )
      send_summaries_at(due_at + 1.minute)
      send_summaries_at(due_at + 2.minutes)
      expect(ActionMailer::Base.deliveries.size).to eq(1)
    end

    it 'is not sent on a day with nothing to report' do
      FactoryBot.create(:info_request, user: user)
      send_summaries_at(user.next_daily_summary_time + 1.minute)
      expect(ActionMailer::Base.deliveries).to be_empty
    end
  end
end
