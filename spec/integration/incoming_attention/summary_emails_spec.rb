require 'spec_helper'

RSpec.describe 'Summary emails' do
  include_context 'with incoming attention off'
  let(:user) { FactoryBot.create(:pro_user, trusted: true) }

  def authority(name)
    FactoryBot.create(:public_body, name: name, short_name: '')
  end

  def response_notice(body_name, files: 0)
    request = FactoryBot.create(:info_request,
                                user: user,
                                public_body: authority(body_name))
    message = FactoryBot.create(:incoming_message, info_request: request)
    files.times {
      FactoryBot.create(:pdf_attachment, incoming_message: message)
    }
    event = request.log_event('response', incoming_message_id: message.id)
    FactoryBot.create(:daily_notification, user: user,
                                           info_request_event: event)
  end

  def late_notice(body_name)
    request = FactoryBot.create(:info_request,
                                user: user,
                                public_body: authority(body_name))
    event = request.log_event('overdue', {})
    FactoryBot.create(:daily_notification, user: user,
                                           info_request_event: event)
  end

  describe 'the setting' do
    it 'is the daily summary unless the account chooses an email for each reply' do
      expect(user.notification_frequency).to eq(Notification::DAILY)
      sign_in(user)
      get "/user/#{user.url_name}"
      setting = Nokogiri::HTML(response.body).css('.account-settings li').find { |row| row.text.include?('Emails about replies') }
      expect(setting.at_css('.account-settings__value').text).
        to eq('One summary a day')

      post '/profile/emails', params: { emails: 'each' }
      expect(flash[:notice]).to eq('You’ll get an email for each reply.')
      expect(user.reload.notification_frequency).to eq(Notification::INSTANTLY)
      post '/profile/emails', params: { emails: 'daily' }
      expect(user.reload.notification_frequency).to eq(Notification::DAILY)
      post '/profile/emails', params: { emails: 'sometimes' }
      expect(flash[:error]).to eq('Choose how you get emails about replies.')
      expect(user.reload.notification_frequency).to eq(Notification::DAILY)
    end

    it 'asks a visitor to sign in' do
      get '/profile/emails'
      expect(response).to redirect_to(%r{/profile/sign_in})
    end

    it 'sends an opted-in account one email for a reply, saying who replied' do
      IncomingAttention::InstantEmails.set!(user, true)
      request = FactoryBot.create(:info_request,
                                  user: user,
                                  public_body: authority('Fife Council'))
      ActionMailer::Base.deliveries.clear
      receive_incoming_mail(info_request: request)
      expect(user.notifications.last.frequency).to eq('instantly')
      NotificationMailer.send_instant_notifications
      mail = ActionMailer::Base.deliveries.last
      expect(mail.subject).to eq('Fife Council replied')
      expect(mail.body.decoded).
        to include('Fife Council replied.', 'An email as replies arrive.')
    end
  end
end
