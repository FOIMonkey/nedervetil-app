require 'spec_helper'
require 'timeout'

RSpec.describe 'Resending a failed message' do
  include_context 'with incoming attention off'

  # Monday 7 September 2026; due 5 October (20 working days).
  let(:start) { Time.zone.parse('2026-09-07 10:00') }
  let(:user) { FactoryBot.create(:user) }
  let(:admin) { FactoryBot.create(:admin_user) }

  def request_sent
    travel_to(start) { FactoryBot.create(:info_request, user: user) }
  end

  def reply(request, at:, state:)
    travel_to(at) do
      message = FactoryBot.create(:incoming_message, info_request: request)
      request.log_event('response', incoming_message_id: message.id)
      request.reload.set_described_state(state)
    end
  end

  def failed_follow_up(request, at:, what_doing: 'normal_sort')
    travel_to(at) do
      OutgoingMessage.create!(info_request: request.reload,
                              status: 'ready',
                              message_type: 'followup',
                              what_doing: what_doing,
                              body: "Dear Authority,\n\nPlease see my " \
                                    "follow-up.\n\nYours " \
                                    "faithfully,\n\n#{user.name}").
        tap { |message|
          message.record_email_failure('The mail server refused it')
        }
    end
  end

  def resend(message, at:)
    travel_to(at) do
      sign_in(admin)
      post "/admin/outgoing_messages/#{message.id}/resend"
    end
    expect(response).to redirect_to(%r{/admin/requests/})
    reset!
    message.info_request.reload
  end

  def header_for_owner(request)
    sign_in(user)
    get "/request/#{request.url_title}"
    Nokogiri::HTML(response.body).at_css('.next-step')&.text&.
      squish || response.body
  end

  def action(request, on:)
    Deadlines::NextAction.for(request.reload, today: on.to_date)
  end

  it 'puts an ordinary follow-up back to waiting, keeping the original deadline and history' do
    request = request_sent
    message = failed_follow_up(request, at: start + 7.days)
    expect(request.reload.described_state).to eq('error_message')
    expect(action(request, on: start + 8.days).kind).to eq(:delivery)
    history = request.info_request_events.order(:id).pluck(:event_type)
    expect(history).to eq(%w[sent send_error])

    resend(message, at: start + 9.days)

    expect(request.described_state).to eq('waiting_response')
    expect(request.date_response_required_by).to eq(Date.new(2026, 10, 5))
    expect(request.info_request_events.order(:id).pluck(:event_type)).
      to eq(history + %w[followup_resent])
    expect(request.info_request_events.find_by(
      event_type: 'send_error'
    ).described_state).to eq('error_message')
    expect(message.reload.status).to eq('sent')
    expect(action(request, on: start + 10.days)).
      to have_attributes(kind: :response, date: Date.new(2026, 10, 5))

    header = header_for_owner(request)
    expect(header).not_to include('Delivery problem')
    expect(header).to match(/Waiting for|Response overdue/)
  end

  it 'answers a clarification on resend, restarting the clock as core does for a first send' do
    request = request_sent
    reply(request, at: start + 3.days, state: 'waiting_clarification')
    message = failed_follow_up(request, at: start + 7.days)

    resend(message, at: Time.zone.parse('2026-09-16 10:00'))

    expect(request.described_state).to eq('waiting_response')
    expect(request.date_response_required_by).to eq(Date.new(2026, 10, 14))
  end

  it 'returns a request marked complete to its final status, awaiting a reply to the follow-up' do
    request = request_sent
    reply(request, at: start + 7.days, state: 'successful')
    travel_to(start + 8.days) do
      Deadlines::Closure.close!(
        request.reload,
        user: user,
        final_state: 'successful',
        last_event_id: request.info_request_events.maximum(:id)
      )
    end
    message = failed_follow_up(request, at: start + 9.days)

    resend(message, at: start + 10.days)

    expect(request.described_state).to eq('successful')
    expect(action(request, on: start + 11.days)).
      to have_attributes(kind: :follow_up, date: (start + 10.days).to_date)
  end

  it 'still shows a delivery problem when the resend fails too' do
    request = request_sent
    message = failed_follow_up(request, at: start + 7.days)
    travel_to(start + 9.days) do
      message.prepare_message_for_resend
      message.record_email_failure('The mail server refused it again')
    end

    expect(request.reload.described_state).to eq('error_message')
    expect(action(request, on: start + 10.days).kind).to eq(:delivery)
    expect(header_for_owner(request)).to include('Delivery problem')
  end

  it 'leaves the status alone while a reply is waiting to be read' do
    request = request_sent
    message = failed_follow_up(request, at: start + 7.days)
    travel_to(start + 8.days) do
      incoming = FactoryBot.create(:incoming_message, info_request: request)
      request.log_event('response', incoming_message_id: incoming.id)
      request.update!(awaiting_description: true)
    end

    resend(message, at: start + 9.days)

    expect(request.awaiting_description).to be(true)
    expect(request.calculate_status).to eq('waiting_classification')
  end

  it 'preserves an unread automatic classification even when core is no longer awaiting description' do
    request = request_sent
    message = failed_follow_up(request, at: start + 7.days)
    incoming = FactoryBot.create(:incoming_message, info_request: request)
    request.log_event('response', incoming_message_id: incoming.id)
    request.update!(awaiting_description: false)
    prediction = IncomingAttention::Prediction.create!(
      incoming_message: incoming,
      info_request: request,
      status: 'complete',
      route: 'SKIP',
      needs_check: false,
      eligible: true,
      restrictions: [],
      attempts: 1,
      auto_classified: true
    )
    allow(IncomingAttention::Config).to receive(:enabled?).and_return(true)

    resend(message, at: start + 9.days)

    expect(request.described_state).to eq('error_message')
    expect(prediction.reload.human_reviewed_at).to be_nil
    expect(IncomingAttention::Effective.unresolved(
             IncomingMessage.where(id: incoming.id)
           )).to exist
    expect(incoming.response_event.reload.described_state).to be_nil
  end

  it 'keeps a newer failed follow-up visible when an older successful resend is repeated' do
    request = request_sent
    older = failed_follow_up(request, at: start + 7.days)
    resend(older, at: start + 8.days)
    newer = failed_follow_up(request, at: start + 9.days)

    resend(older, at: start + 10.days)

    expect(newer.reload.status).to eq('failed')
    expect(request.described_state).to eq('error_message')
    expect(action(request, on: start + 11.days).kind).to eq(:delivery)
    expect(header_for_owner(request)).to include('Delivery problem')
  end

  it 'keeps a failed follow-up visible when another message is resent' do
    request = request_sent
    older = travel_to(start + 3.days) {
      FactoryBot.create(:new_information_followup, info_request: request)
    }
    failed_follow_up(request, at: start + 7.days)

    resend(older, at: start + 9.days)

    expect(request.described_state).to eq('error_message')
    expect(action(request, on: start + 10.days).kind).to eq(:delivery)
  end

  context 'a reply arriving during status restoration' do
    # A second database connection must see the request and contend for its
    # real row lock, so this example uses committed, explicitly cleaned data.
    self.use_transactional_tests = false

    after do
      @resend_request&.destroy!
      @resend_authority&.destroy!
      user.destroy!
    end

    it 'leaves the arriving reply unread and unclassified' do
      request = @resend_request = request_sent
      @resend_authority = request.public_body
      message = failed_follow_up(request, at: start + 7.days)
      mail = Mail.new do
        from 'synthetic-officer@example.invalid'
        to request.incoming_email
        subject 'Synthetic reply arriving during resend'
        message_id "resend-race-#{SecureRandom.uuid}@example.invalid"
        content_type 'text/plain; charset=UTF-8'
        body 'Wholly synthetic correspondence.'
      end
      receipt = nil
      backend_ids = Queue.new

      # Start core's real receipt after the resend's checks, just before it
      # writes the status. Without the shared request lock the reply wins
      # this race and is then classified unseen by the resend.
      allow(message).
        to receive(:automatic).and_wrap_original do |original, &block|
        receipt = Thread.new do
          ActiveRecord::Base.connection_pool.with_connection do |connection|
            backend_ids << connection.select_value('SELECT pg_backend_pid()')
            InfoRequest.find(request.id).send(:create_response!, mail)
          end
        end
        backend_id = Timeout.timeout(5) { backend_ids.pop }
        Timeout.timeout(5) do
          loop do
            break unless receipt.alive?

            blockers = ActiveRecord::Base.connection.select_value(
              "SELECT cardinality(pg_blocking_pids(#{Integer(backend_id)}))"
            )
            break if blockers.positive?

            sleep 0.01
          end
        end
        original.call(&block)
      end

      message.prepare_message_for_resend
      message.record_email_delivery(request.public_body.request_email,
                                    '<resend@synthetic.test>',
                                    'resent')
      incoming = Timeout.timeout(5) { receipt.value }

      expect(request.reload.awaiting_description?).to be(true)
      expect(request.calculate_status).to eq('waiting_classification')
      expect(incoming.response_event.reload.described_state).to be_nil
      expect(incoming.response_event.last_described_at).to be_nil
    ensure
      receipt&.join(5)
      receipt&.kill if receipt&.alive?
    end
  end

  context 'regressions' do
    it 'leaves core resending the initial request: waiting, with the clock from the resend' do
      request = travel_to(start) do
        FactoryBot.create(:info_request, user: user).tap do |r|
          r.outgoing_messages.first.
            record_email_failure('The mail server refused it')
        end
      end
      expect(request.reload.described_state).to eq('error_message')

      resend(request.outgoing_messages.first,
             at: Time.zone.parse('2026-09-09 10:00'))

      expect(request.described_state).to eq('waiting_response')
      expect(request.date_response_required_by).to eq(Date.new(2026, 10, 7))
    end

    it 'leaves core resending an internal review, and counts the review from the resend' do
      request = request_sent
      reply(request, at: start + 7.days, state: 'rejected')
      message = failed_follow_up(request, at: start + 8.days,
                                          what_doing: 'internal_review')
      expect(request.reload.described_state).to eq('error_message')

      resend(message, at: Time.zone.parse('2026-09-21 10:00'))

      expect(request.described_state).to eq('internal_review')
      expect(request.date_response_required_by).to eq(Date.new(2026, 10, 5))
      expect(action(request, on: Date.new(2026, 9, 22))).
        to have_attributes(kind: :review, date: Date.new(2026, 10, 19))
    end
  end
end
