require 'spec_helper'

RSpec.describe 'Request deadlines' do
  # Monday 7 September 2026; due 5 October (20 working days).
  let(:start) { Time.zone.parse('2026-09-07 10:00') }

  include_context 'with incoming attention off' if defined?(IncomingAttention::Config)
  let(:user) { FactoryBot.create(:user, trusted: true) }

  def request_sent(at: start, **attrs)
    travel_to(at) { FactoryBot.create(:info_request, user: user, **attrs) }
  end

  def reply(request, at:, state:)
    travel_to(at) do
      message = FactoryBot.create(:incoming_message, info_request: request)
      request.log_event('response', incoming_message_id: message.id)
      request.reload.set_described_state(state)
    end
  end

  def review_requested(request, at:)
    travel_to(at) {
      FactoryBot.create(:internal_review_request, info_request: request.reload)
    }
    request.reload
  end

  def action(request, on:)
    Deadlines::NextAction.for(request.reload, today: on.to_date)
  end

  describe 'changing a due date from the request page' do
    let(:info_request) { request_sent }

    it 'shows the requester the Deadlines panel, and lets them change the date' do
      sign_in(user)
      get "/request/#{info_request.url_title}"
      expect(response.body).to include('id="deadlines"', 'Change the due date')

      post "/deadlines/#{info_request.id}/response",
           params: { due_on: '2026-11-02',
                     reason: 'public_interest',
                     note: 'Letter of 1 Oct' }
      expect(response).
        to redirect_to("/request/#{info_request.url_title}#deadlines")
      expect(info_request.reload.date_response_required_by).
        to eq(Date.new(2026, 11, 2))
      expect(Deadlines::Adjustment.last).
        to have_attributes(user_id: user.id, note: 'Letter of 1 Oct')

      post "/deadlines/#{info_request.id}/response/restore"
      expect(info_request.reload.date_response_required_by).
        to eq(Date.new(2026, 10, 5))
    end

    it 'is a 404 for anyone else, signed in or not, and changes nothing' do
      sign_in(FactoryBot.create(:user))
      post "/deadlines/#{info_request.id}/response",
           params: { due_on: '2026-11-02', reason: 'agreed' }
      expect(response).to have_http_status(:not_found)

      reset!
      post "/deadlines/#{info_request.id}/response",
           params: { due_on: '2026-11-02', reason: 'agreed' }
      expect(response).to have_http_status(:not_found)
      expect(info_request.reload.date_response_required_by).
        to eq(Date.new(2026, 10, 5))
    end

    it 'does not show the panel to anyone else' do
      sign_in(FactoryBot.create(:user))
      get "/request/#{info_request.url_title}"
      expect(response.body).not_to include('id="deadlines"')
    end

    it 'explains a date it could not use' do
      sign_in(user)
      post "/deadlines/#{info_request.id}/response",
           params: { due_on: '2026-01-01', reason: 'agreed' }
      expect(flash[:error]).to include('wasn’t changed')
      expect(info_request.reload.date_response_required_by).
        to eq(Date.new(2026, 10, 5))
    end
  end

  describe 'dates written to core' do
    it 'hold back core’s overdue event until the new date, then log it once' do
      request = request_sent(use_notifications: false)
      travel_to(Time.zone.parse('2026-10-08 10:00')) do
        Deadlines::Adjustment.apply!(request, stage: 'response', user: user,
                                              due_on: Date.new(2026, 10, 20),
                                              reason: 'public_interest')
        InfoRequest.log_overdue_events
        expect(request.info_request_events.where(event_type: 'overdue')).
          to be_empty
      end

      travel_to(Time.zone.parse('2026-10-22 10:00')) do
        expect(request.reload.calculate_status).
          to eq('waiting_response_overdue')
        InfoRequest.log_overdue_events
        InfoRequest.log_overdue_events
        expect(request.info_request_events.where(event_type: 'overdue').count).
          to eq(1)
      end
    end

    it 'move the request between the Pro phase lists' do
      request = request_sent
      travel_to(Time.zone.parse('2026-10-08 10:00')) do
        expect(InfoRequest.overdue).to include(request)
        Deadlines::Adjustment.apply!(request, stage: 'response', user: user,
                                              due_on: Date.new(2026, 10, 20),
                                              reason: 'agreed')
        expect(InfoRequest.overdue).not_to include(request)
        expect(request.reload.state.phase).to eq(:awaiting_response)
      end
    end
  end

  describe 'permissions for marking complete and changing dates' do
    let(:info_request) { request_sent }
    let(:last_event_id) { info_request.info_request_events.maximum(:id) }

    def mark_complete(state = 'successful', **extra)
      post "/deadlines/#{info_request.id}/complete",
           params: { final_state: state, last_event_id: last_event_id, **extra }
    end

    it 'lets the requester mark their request complete from the dashboard' do
      sign_in(user)
      mark_complete('partially_successful', return_to: 'dashboard')

      expect(response).
        to redirect_to(
          '/pro/dashboard#deadlines-action_required-title'
        ).or redirect_to(
          '/alaveteli_pro/dashboard#deadlines-action_required-title'
        )
      expect(info_request.reload.described_state).to eq('partially_successful')

      post "/deadlines/#{info_request.id}/reopen"
      expect(Deadlines::Closure.current(info_request.reload)).to be_nil
      expect(info_request.described_state).to eq('partially_successful')
    end

    it 'lets an admin act on someone else’s request' do
      sign_in(FactoryBot.create(:admin_user))
      mark_complete
      expect(info_request.reload.described_state).to eq('successful')
    end

    it 'is a 404 for another user or a signed-out visitor' do
      sign_in(FactoryBot.create(:user))
      mark_complete
      expect(response).to have_http_status(:not_found)
      post "/deadlines/#{info_request.id}/reopen"
      expect(response).to have_http_status(:not_found)

      reset!
      mark_complete
      expect(response).to have_http_status(:not_found)

      expect(info_request.reload.described_state).to eq('waiting_response')
    end

    it 'is a 404 for a requester who can no longer read their request' do
      info_request.update!(prominence: 'hidden')
      sign_in(user)
      mark_complete
      expect(response).to have_http_status(:not_found)
      post "/deadlines/#{info_request.id}/response",
           params: { due_on: '2026-11-02', reason: 'agreed' }
      expect(response).to have_http_status(:not_found)
      expect(info_request.reload.described_state).to eq('waiting_response')
    end

    it 'needs a final status, and never redirects anywhere but the dashboard or the request' do
      sign_in(user)
      mark_complete('waiting_response', return_to: 'https://example.com/')
      expect(response).
        to redirect_to("/request/#{info_request.url_title}#deadlines")
      expect(flash[:error]).to include('Choose the final status')
      expect(info_request.reload.described_state).to eq('waiting_response')
    end

    it 'changes nothing while the site is in read-only maintenance mode' do
      sign_in(user)
      allow(AlaveteliConfiguration).
        to receive(:read_only).and_return('Back soon.')

      mark_complete
      expect(response).to redirect_to('/')
      post "/deadlines/#{info_request.id}/response",
           params: { due_on: '2026-11-02', reason: 'agreed' }
      expect(response).to redirect_to('/')

      expect(info_request.reload.described_state).to eq('waiting_response')
      expect(info_request.date_response_required_by).
        to eq(Date.new(2026, 10, 5))
      expect(Deadlines::Closure.count + Deadlines::Adjustment.count).to eq(0)
    end

    it 'only changes the due date the request is waiting on now' do
      reply(info_request, at: start + 7.days, state: 'successful')
      sign_in(user)
      post "/deadlines/#{info_request.id}/response",
           params: { due_on: '2026-11-02', reason: 'agreed' }

      expect(flash[:error]).to include('no deadline to change')
      expect(info_request.reload.date_response_required_by).
        to eq(Date.new(2026, 10, 5))
      expect(Deadlines::Adjustment.count).to eq(0)
    end

    it 'rejects a form without the CSRF token' do
      sign_in(user)
      ActionController::Base.allow_forgery_protection = true
      rejected = begin
        mark_complete
        response.status == 422
                 rescue ActionController::InvalidAuthenticityToken
                   true
      end
      expect(rejected).to be(true)
      expect(info_request.reload.described_state).to eq('waiting_response')
      expect(Deadlines::Closure.count).to eq(0)
    ensure
      ActionController::Base.allow_forgery_protection = false
    end

    it 'shows Mark complete on the dashboard and in the panel, and not to others' do
      sign_in(user)
      get "/request/#{info_request.url_title}"
      expect(response.body).to include("/deadlines/#{info_request.id}/complete")

      reset!
      sign_in(FactoryBot.create(:user))
      get "/request/#{info_request.url_title}"
      expect(response.body).
        not_to include("/deadlines/#{info_request.id}/complete")
    end
  end

  describe 'the Deadlines panel' do
    it 'is shown on a private request to its requester' do
      pro = FactoryBot.create(:pro_user)
      request = travel_to(start) {
        FactoryBot.create(:info_request, user: pro)
      }
      sign_in(pro)
      get "/request/#{request.url_title}"
      follow_redirect! while response.redirect?

      expect(response.body).to include('id="deadlines"')
    end
  end
end
