require 'spec_helper'

RSpec.describe 'Independent reviewed-send contracts', type: :request, feature: :alaveteli_pro do
  include_context 'with incoming attention off'
  include_context 'with request limits on'
  let(:owner) { FactoryBot.create(:user, name: 'Rowan Requester') }
  let(:council) { FactoryBot.create(:public_body) }

  def issued_send_form
    sign_in(owner)
    post '/pro/info_requests', params: {
      info_request: { title: 'Repair totals 2025', public_body_id: council.id },
      outgoing_message: { body: RequestLetter.join(
        'Please provide repair totals for 2025.', council.name, owner.name
      ) },
      review: 1
    }
    follow_redirect! while response.redirect?
    form = Nokogiri::HTML(response.body).css('form').find { |f| f.at_css('#submit_button') }
    expect(form).to be_present
    field = ->(name) { form.at_css("input[name=\"#{name}\"]")['value'] }
    [form['action'], { draft_id: field.call('draft_id'),
                       review_token: field.call('review_token') }]
  end

  it 'does not create another request or send another email when the successful review form is replayed' do
    path, form = issued_send_form
    post path, params: form
    expect(owner.info_requests.count).to eq(1)
    requests = owner.info_requests.pluck(:id)
    deliveries = ActionMailer::Base.deliveries.size
    2.times { post path, params: form }
    expect(owner.info_requests.pluck(:id)).to eq(requests)
    expect(ActionMailer::Base.deliveries.size).to eq(deliveries)
  end
end

RSpec.describe 'Independent resend and arriving reply contracts' do
  include_context 'with incoming attention off'
  let(:owner) { FactoryBot.create(:user) }
  let(:start) { Time.zone.parse('2026-09-07 10:00') }
  let(:request_record) {
  travel_to(start) {
  FactoryBot.create(:info_request, user: owner)
}
}

  def failed_followup
    target = request_record
    travel_to(start + 7.days) do
      body = "Dear Authority,\n\nPlease provide an update.\n\n" \
             "Yours faithfully,\n\n#{owner.name}"
      OutgoingMessage.create!(
        info_request: target, status: 'ready', message_type: 'followup',
        what_doing: 'normal_sort', body: body
      ).tap do |outgoing|
        outgoing.record_email_failure('Synthetic transport refusal')
      end
    end
  end

  def incoming
    mail = Mail.new do
      from 'officer@example.invalid'
      subject 'Synthetic reply during resend'
      message_id "validation-#{SecureRandom.uuid}@example.invalid"
      content_type 'text/plain; charset=UTF-8'
      body 'The repair total is 1204. Wholly synthetic correspondence.'
    end
    mail.to = request_record.incoming_email
    request_record.reload.send(:create_response!, mail)
  end

  [true, false].each do |reply_first|
    it "preserves an unread reply arriving #{reply_first ? 'before' : 'after'} the resend delivery callback" do
      outgoing = failed_followup
      deadline = request_record.reload.date_response_required_by
      outgoing.prepare_message_for_resend
      delivered = -> {
        outgoing.record_email_delivery(
          request_record.public_body.request_email,
          '<synthetic-resend@example.invalid>', 'resent'
        )
      }
      travel_to(start + 9.days) do
        if reply_first
          message = incoming
          delivered.call
        else
          delivered.call
          message = incoming
        end
        expect(request_record.reload.awaiting_description?).to be(true)
        expect(request_record.date_response_required_by).to eq(deadline)
        expect(message.response_event.reload.described_state).to be_nil
        expect(message.response_event.last_described_at).to be_nil
        expect(outgoing.reload.status).to eq('sent')
      end
    end
  end

  it 'preserves a human decision made after resend preparation but before delivery confirmation' do
    outgoing = failed_followup
    outgoing.prepare_message_for_resend
    incoming
    request_record.reload.set_described_state('rejected', owner)
    outgoing.record_email_delivery(
      request_record.public_body.request_email,
      '<synthetic-human-decision@example.invalid>', 'resent'
    )
    expect(request_record.reload.described_state).to eq('rejected')
    expect(request_record.awaiting_description?).to be(false)
  end

  it 'records no review and no override when a clarification is answered' do
    asking = incoming
    asked = IncomingAttention::Prediction.create!(
      incoming_message: asking, info_request: request_record,
      status: 'complete', route: 'REVIEW', needs_check: true, eligible: true,
      restrictions: [], attempts: 1,
      outcome_applied_state: 'waiting_clarification'
    )
    request_record.reload.update_columns(
      described_state: 'waiting_clarification', awaiting_description: false
    )
    answer = OutgoingMessage.create!(
      info_request: request_record.reload, status: 'ready',
      message_type: 'followup', what_doing: 'normal_sort',
      body: "Dear Authority,\n\nI meant 2025.\n\nYours faithfully,\n\n" \
            "#{owner.name}"
    )

    answer.record_email_delivery(request_record.public_body.request_email,
                                 '<synthetic-answer@example.invalid>')

    expect(request_record.reload.described_state).to eq('waiting_response')
    expect(asked.reload.outcome_overridden_from).to be_nil
    expect(asked.human_reviewed_at).to be_nil
  end

  it 'keeps a newer reply waiting, and the status as it was, when a ' \
     'clarification is answered' do
    incoming
    request_record.reload.update_columns(
      described_state: 'waiting_clarification', awaiting_description: false
    )
    newer = IncomingAttention::Prediction.create!(
      incoming_message: incoming, info_request: request_record,
      status: 'complete', route: 'REVIEW', needs_check: true, eligible: true,
      restrictions: [], attempts: 1
    )
    answer = OutgoingMessage.create!(
      info_request: request_record.reload, status: 'ready',
      message_type: 'followup', what_doing: 'normal_sort',
      body: "Dear Authority,\n\nI meant 2025.\n\nYours faithfully,\n\n" \
            "#{owner.name}"
    )

    answer.record_email_delivery(request_record.public_body.request_email,
                                 '<synthetic-answer@example.invalid>')

    expect(request_record.reload.awaiting_description?).to be(true)
    expect(request_record.described_state).to eq('waiting_clarification')
    expect(IncomingAttention::Effective.reviewed?(newer.incoming_message)).
      to be(false)
  end

  it 'keeps a delivery failure and an arriving reply separately actionable' do
    outgoing = failed_followup
    outgoing.prepare_message_for_resend
    message = incoming
    prediction = IncomingAttention::Prediction.create!(
      incoming_message: message, info_request: request_record,
      status: 'complete', route: 'REVIEW', needs_check: true, eligible: true,
      restrictions: [], attempts: 1
    )
    expect(prediction.human_reviewed_at).to be_nil
    outgoing.record_email_failure('Synthetic repeated transport refusal')
    aggregate_failures 'transport failure is not a human review' do
      expect(outgoing.reload.status).to eq('failed')
      expect(request_record.reload.awaiting_description?).to be(true)
      expect(prediction.reload.human_reviewed_at).to be_nil
      expect(message.response_event.reload.described_state).to be_nil
      expect(message.response_event.last_described_at).to be_nil
    end
  end
end

RSpec.describe 'A follow-up sent while a reply is unread' do
  include_context 'with lean attention predictions'
  let(:owner) { FactoryBot.create(:user) }
  let(:start) { Time.zone.parse('2026-09-07 10:00') }

  def new_request
    travel_to(start) { FactoryBot.create(:info_request, user: owner) }
  end

  def reply(request, at)
    travel_to(at) do
      mail = Mail.new do
        from 'officer@example.invalid'
        subject 'Synthetic reply'
        message_id "send-read-#{SecureRandom.uuid}@example.invalid"
        content_type 'text/plain; charset=UTF-8'
        body 'Wholly synthetic correspondence.'
      end
      mail.to = request.incoming_email
      request.reload.send(:create_response!, mail)
    end
  end

  def classify(request, state, at)
    travel_to(at) { request.reload.set_described_state(state, owner) }
  end

  def send_followup(request, what_doing, at)
    travel_to(at) do
      OutgoingMessage.create!(
        info_request: request.reload, status: 'ready',
        message_type: 'followup', what_doing: what_doing,
        body: "Dear Authority,\n\nSynthetic.\n\nYours faithfully,\n\n" \
              "#{owner.name}"
      ).tap do |message|
        message.record_email_delivery(request.public_body.request_email,
                                      "<send-read-#{SecureRandom.uuid}@x>")
      end
    end
  end

  def sent_event(message)
    message.info_request.info_request_events.
      where(outgoing_message_id: message.id).last
  end

  def expect_unread(message)
    request = message.info_request.reload
    event = message.response_event.reload
    aggregate_failures 'the reply is as it arrived' do
      expect(request.awaiting_description?).to be(true)
      expect(IncomingAttention::Prediction.for_message(message).
             human_reviewed_at).to be_nil
      expect(event.described_state).to be_nil
      expect(event.last_described_at).to be_nil
      expect(IncomingAttention::Effective.reviewed?(message.reload)).
        to be(false)
      expect(IncomingAttention::Effective.
             unresolved(IncomingMessage.where(id: message.id))).to exist
    end
  end

  it 'answers a clarification without reading the newer reply, and ' \
     'restarts the clock as it would without it' do
    with_reply = new_request
    without = new_request
    [with_reply, without].each do |request|
      reply(request, start + 2.days)
      classify(request, 'waiting_clarification', start + 2.days + 1.hour)
    end
    first_due = without.reload.date_response_required_by
    newer = reply(with_reply, start + 4.days)

    answer = send_followup(with_reply, 'normal_sort', start + 6.days)
    control = send_followup(without, 'normal_sort', start + 6.days)

    expect(without.reload.described_state).to eq('waiting_response')
    expect(sent_event(control).described_state).to eq('waiting_response')

    expect_unread(newer)
    expect(with_reply.reload.described_state).to eq('waiting_clarification')
    expect(sent_event(answer).described_state).to be_nil

    expect(with_reply.date_initial_request_last_sent_at).
      to eq((start + 6.days).to_date)
    expect(with_reply.date_response_required_by).
      to eq(without.date_response_required_by)
    expect(with_reply.date_response_required_by).to be > first_due
  end

  it 'asks for an internal review without reading the newer reply, and ' \
     'shows the review date once the reply is classified as a review' do
    with_reply = new_request
    without = new_request
    [with_reply, without].each do |request|
      reply(request, start + 10.days)
      classify(request, 'rejected', start + 10.days + 1.hour)
    end
    newer = reply(with_reply, start + 12.days)
    lean_prediction(newer, 'REVIEW')

    review = send_followup(with_reply, 'internal_review', start + 14.days)
    control = send_followup(without, 'internal_review', start + 14.days)

    expect(without.reload.described_state).to eq('internal_review')
    expect(Deadlines::Stage.review_basis(without)).to eq(sent_event(control))
    review_due = Deadlines::NextAction.for(without)
    expect(review_due.kind).to eq(:review)

    expect_unread(newer)
    expect(with_reply.reload.described_state).to eq('rejected')
    expect(sent_event(review).described_state).to be_nil
    held = Deadlines::NextAction.for(with_reply)
    expect(held.kind).to eq(:read_reply)
    expect(held.date).not_to eq(review_due.date)

    classify(with_reply, 'internal_review', start + 15.days)
    shown = Deadlines::NextAction.for(with_reply.reload)
    expect(shown.kind).to eq(:review)
    expect(shown.date).to eq(review_due.date)
  end

  # The fail-safe edge: events can't tell an unclassified refusal from a
  # newer reply, so the review status waits for the classification.
  it 'leaves an unclassified refusal unread when a review is asked for' do
    request = new_request
    refusal = reply(request, start + 10.days)

    send_followup(request, 'internal_review', start + 14.days)

    expect_unread(refusal)
    expect(request.reload.described_state).to eq('waiting_response')
    expect(request.calculate_status).to eq('waiting_classification')
  end

  it 'leaves a newer reply unread when an ordinary follow-up is sent' do
    request = new_request
    newer = reply(request, start + 4.days)

    send_followup(request, 'normal_sort', start + 6.days)

    expect_unread(newer)
    expect(request.reload.described_state).to eq('waiting_response')
  end
end
