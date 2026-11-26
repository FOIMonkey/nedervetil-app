require 'spec_helper'

RSpec.describe 'Home and reminders', feature: :alaveteli_pro do
  include_context 'with incoming attention off'
  let(:user) { FactoryBot.create(:pro_user) }
  let(:start) { Time.zone.parse('2026-09-07 10:00') }
  let(:late_day) { Time.zone.parse('2026-10-09 12:00') }

  # A session expires ApplicationController::SESSION_TTL after the last
  # request, so this signs in at the test's own time.
  def sign_in_at(person, at: late_day)
    travel_to(at) { sign_in(person) }
  end

  def request_sent(**attrs)
    travel_to(start) { FactoryBot.create(:info_request, user: user, **attrs) }
  end

  def remind(request, on: late_day, **params)
    travel_to(on) { post "/deadlines/#{request.id}/remind", params: params }
  end

  def reminder_mails
    ActionMailer::Base.deliveries.
      select { |mail| mail.subject.to_s.start_with?('Re: ') }
  end

  include_context 'with request limits on'

  it 'offers one click on Home for a late request, sends the standard reminder once, and shows when' do
    request = request_sent
    sign_in_at(user)
    travel_to(late_day) { get alaveteli_pro_dashboard_path }
    home = Nokogiri::HTML(response.body)
    expect(home.at_css('#content h1').text).to eq('Home')
    row = home.at_css("[data-pile='needs'] [data-request-id='#{request.id}']")
    expect(row.at_css('.pile__reason').text.squish).to eq('Late · due 5 Oct')
    expect(row.at_css('.pile__remind button').text.squish).
      to start_with('Remind them')
    expect(home.css('.home-spots li').map { |tile| tile.text.squish }).
      to include('1 Late Due 5 Oct')

    ActionMailer::Base.deliveries.clear
    expect { remind(request, return_to: 'home') }.
      not_to(change { RequestLimits::Send.where(kind: 'followup').count })
    expect(response).to redirect_to(alaveteli_pro_dashboard_path)
    expect(reminder_mails.size).to eq(1)
    mail = reminder_mails.first
    expect(mail.to).to eq([request.public_body.request_email])
    expect(mail.body.decoded).to include(
      "Dear #{request.public_body.name},",
      "I haven't yet had a reply to my request \"#{request.title}\", sent on " \
      "7 September 2026. It was due by 5 October 2026.",
      'Please reply as soon as you can.', user.name
    )
    expect(Deadlines::Reminder.for(request, :response, Date.new(2026, 10, 5)).
             outgoing_message.status).to eq('sent')

    travel_to(late_day + 1.hour) { get alaveteli_pro_dashboard_path }
    row = Nokogiri::HTML(response.body).
      at_css("[data-request-id='#{request.id}']")
    expect(row.at_css('.pile__reason').text.squish).
      to eq('Late · due 5 Oct · reminded 9 Oct')
    expect(row.at_css('.pile__remind')).to be_nil

    expect { remind(request, on: late_day + 2.hours) }.
      not_to(change { reminder_mails.size })
  end

  it 'doesn’t count a reminder that couldn’t be sent' do
    request = request_sent
    sign_in_at(user)
    undeliverable = double('mail')
    allow(undeliverable).to receive(:deliver_now).and_raise(Errno::ECONNRESET)
    allow(OutgoingMailer).to receive(:followup).and_return(undeliverable)
    remind(request, return_to: 'home')
    expect(flash[:error]).
      to eq('The reminder couldn’t be sent. Contact us and we’ll send it.')
    expect(Deadlines::Reminder.where(info_request_id: request.id)).to be_empty
    expect(request.outgoing_messages.where(message_type: 'followup').
             last.status).to eq('failed')
  end

  it 'sends at most one reminder a week on a request, however its due date changes' do
    request = request_sent
    sign_in_at(user)
    ActionMailer::Base.deliveries.clear
    remind(request)
    travel_to(late_day) do
      post "/deadlines/#{request.id}/response",
           params: { due_on: '2026-10-06', reason: 'other' }
    end
    expect(Deadlines::Adjustment.current(request.reload, 'response').due_on).
      to eq(Date.new(2026, 10, 6))

    remind(request)
    expect(flash[:notice]).to eq('There’s nothing to remind them about now.')
    travel_to(late_day) { get "/request/#{request.url_title}" }
    expect(Nokogiri::HTML(response.body).at_css('.next-step--act').text).
      to include('Reminded 9 Oct')

    a_week_on = late_day + 7.days + 1.hour
    sign_in_at(user, at: a_week_on)
    remind(request, on: a_week_on)
    expect(flash[:notice]).
      to eq("Reminder sent to #{request.public_body.name}.")
    expect(reminder_mails.size).to eq(2)
  end

  it 'puts the reminder on the request page, and says when it went' do
    request = request_sent
    sign_in_at(user)
    travel_to(late_day) { get "/request/#{request.url_title}" }
    panel = Nokogiri::HTML(response.body).at_css('.next-step--act')
    expect(panel.at_css('form button.button').text).to eq('Remind them')
    remind(request)
    expect(response).to redirect_to("/request/#{request.url_title}")
    travel_to(late_day) { get "/request/#{request.url_title}" }
    panel = Nokogiri::HTML(response.body).at_css('.next-step--act')
    expect(panel.text).to include('Reminded 9 Oct')
    expect(panel.at_css('form button')).to be_nil
  end

  it 'reminds about a late internal review in the review\'s words' do
    request = request_sent
    travel_to(start + 7.days) do
      message = FactoryBot.create(:incoming_message, info_request: request)
      request.log_event('response', incoming_message_id: message.id)
      request.reload.set_described_state('rejected')
    end
    travel_to(Time.zone.parse('2026-09-21 10:00')) do
      FactoryBot.create(:internal_review_request, info_request: request.reload)
    end
    sign_in_at(user, at: Time.zone.parse('2026-10-26 12:00'))
    ActionMailer::Base.deliveries.clear
    remind(request, on: Time.zone.parse('2026-10-26 12:00'))
    expect(flash[:notice]).
      to eq("Reminder sent to #{request.public_body.name}.")
    expect(reminder_mails.last.body.decoded).to include(
      "the result of the internal review of my request \"#{request.title}\", " \
      "which I asked for on 21 September 2026. It was due by 19 October 2026."
    )
  end

  it 'is the requester\'s alone, and only when they\'re late' do
    request = request_sent
    sign_in_at(FactoryBot.create(:pro_user))
    remind(request)
    expect(response).to have_http_status(:not_found)
    reset!
    sign_in_at(FactoryBot.create(:admin_user))
    remind(request)
    expect(response).to have_http_status(:not_found)
    reset!
    sign_in_at(user, at: start + 2.days)
    ActionMailer::Base.deliveries.clear
    remind(request, on: start + 2.days)
    expect(flash[:notice]).to eq('There’s nothing to remind them about now.')
    expect(reminder_mails).to be_empty
  end

  it 'keeps the Requests list a click away from Home' do
    request_sent
    sign_in_at(user, at: Time.current)
    get alaveteli_pro_dashboard_path
    page = Nokogiri::HTML(response.body)
    expect(page.at_css('.dashboard-filters a[href="/pro/info_requests"]').text).
      to eq('View all requests')
  end

  it 'gives a new account a way to start' do
    sign_in_at(user, at: Time.current)
    get alaveteli_pro_dashboard_path
    page = Nokogiri::HTML(response.body)
    expect(page.at_css('.home-empty h2').text).to eq('No requests yet')
    expect(page.at_css('.home-empty a').text).to eq('Make request')
  end
end
