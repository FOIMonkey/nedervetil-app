require 'spec_helper'

RSpec.describe 'The requester’s own request page' do
  include_context 'with incoming attention off'
  let(:user) { FactoryBot.create(:pro_user) }
  let(:start) { Time.zone.parse('2026-09-07 10:00') }

  def request_sent
    travel_to(start) { FactoryBot.create(:info_request, user: user) }
  end

  def reply(request, state = nil, at: start + 7.days)
    travel_to(at) do
      message = FactoryBot.create(:incoming_message, info_request: request)
      request.log_event('response', incoming_message_id: message.id)
      request.reload.set_described_state(state) if state
      message
    end
  end

  def response_event(request)
    request.reload.info_request_events.find_by(event_type: 'response')
  end

  describe Deadlines::History do
    it 'titles a reply by the status it carries, in the words of the question' do
      request = request_sent
      reply(request, 'partially_successful')
      expect(described_class.reply_title(request, response_event(request))).
        to eq('You got some of it')
    end

    it 'says just Reply when a reply has no status and no label' do
      request = request_sent
      reply(request)
      expect(described_class.reply_title(request, response_event(request))).
        to eq('Reply')
    end

    it 'names an acknowledgement only when the label exists' do
      request = request_sent
      reply(request)
      allow(IncomingAttention::Effective).
        to receive_messages(active?: true,
                            notification_pending?: false,
                            decision: IncomingAttention::Effective::Decision.new(
                              bucket: 'routine_updates'
                            ))
      { 'Acknowledgement' => 'Reply · Acknowledgement',
        'Routine update' => 'Reply',
        'Other reply to review' => 'Reply',
        'Likely decision or review response' => 'Reply' }.each do |label, title|
        allow(IncomingAttention::Labels).
          to receive(:for_message).and_return(label)
        expect(described_class.reply_title(request, response_event(request))).
          to eq(title)
      end
    end

    it 'lists what happened oldest first, then the date the request is waiting for' do
      request = request_sent
      reply(request, 'rejected')
      today = (start + 10.days).to_date
      history = described_class.new(request.reload,
                                    Ability.new(user),
                                    today: today)
      expect(history.entries.map(&:title)).
        to eq(['Request sent',
               "Reply from #{request.public_body.name}"])
      expect(history.entries.last.meta).to include('You got none of it')
      expect(history.entries.first.meta).
        to eq("You to #{request.public_body.name}")
      action = Deadlines::NextAction.for(request, today: today)
      expect(history.upcoming(action).title).
        to eq('Last day to ask for a review')
    end

    it 'says a reply is hidden from whoever can’t read it, using nothing from the reply' do
      request = request_sent
      message = reply(request, 'rejected')
      message.update!(prominence: 'hidden')
      event = response_event(request)
      entry = described_class.new(request, Ability.new(user)).entries.last
      expect(entry).to have_attributes(kind: :hidden,
                                       title: 'Reply hidden',
                                       meta: nil,
                                       timing: nil,
                                       line: nil,
                                       at: event.created_at)
      admin = Ability.new(FactoryBot.create(:admin_user))
      expect(described_class.new(request, admin).entries.last).
        to have_attributes(kind: :reply,
                           title: "Reply from #{request.public_body.name}")
    end

    it 'keeps the title of a letter of their own that’s hidden' do
      request = request_sent
      request.outgoing_messages.first.update!(prominence: 'hidden')
      entry = described_class.new(request, Ability.new(user)).entries.first
      expect(entry).to have_attributes(kind: :hidden, title: 'Request sent')
    end
  end

  describe Deadlines::NextAction do
    it 'counts the working days left and how much of the time allowed has gone' do
      request = request_sent
      due = request.date_response_required_by
      action = Deadlines::NextAction.for(request, today: Date.new(2026, 9, 21))
      expect(action.days_left).
        to eq(Deadlines::Calendar.working_days_between(Date.new(2026, 9, 21),
                                                       due))
      expect(action.progress).to eq([50, 0])

      late = Deadlines::NextAction.for(request, today: due + 4.days)
      allowed = Deadlines::Calendar.working_days_between(start.to_date, due)
      total = allowed + late.late_days
      expect(late.progress).
        to eq([(100.0 * allowed / total).round,
               (100.0 * late.late_days / total).round])
    end
  end
end
