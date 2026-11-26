require 'spec_helper'

RSpec.describe Deadlines::NextStep do
  include_context 'with incoming attention off' if defined?(IncomingAttention::Config)
  let(:user) { FactoryBot.create(:user, trusted: true) }
  let(:start) { Time.zone.parse('2026-09-07 10:00') }
  let(:soon) { start + 10.days }
  let(:late) { Time.zone.parse('2026-10-09 12:00') }

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

  # A reply as it arrives by email, still waiting for its status.
  def delivered(request)
    travel_to(start + 7.days) do
      AttachmentFixtures.deliver(request, [], text: "Here is our answer.\n")
    end
  end

  def follow_up(request)
    travel_to(start + 8.days) do
      FactoryBot.create(:new_information_followup,
                        info_request: request.reload)
    end
  end

  def close(request)
    travel_to(start + 8.days) do
      Deadlines::Closure.close!(
        request.reload,
        user: user,
        final_state: 'successful',
        last_event_id: request.info_request_events.maximum(:id)
      )
    end
  end

  # The step as the page builds it. Call it on the day the page is viewed.
  def step_for(request, unread: [], **options)
    described_class.new(
      Deadlines::NextAction.for(InfoRequest.find(request.id)),
      unread: unread, ability: Ability.new(user), **options
    )
  end

  describe '#panel' do
    it 'waits while the authority has time left' do
      request = request_sent
      travel_to(start + 2.days) do
        expect(step_for(request).panel).to eq(:waiting)
      end
    end

    it 'asks the requester to act once the reply is late' do
      request = request_sent
      travel_to(late) { expect(step_for(request).panel).to eq(:act) }
    end

    it 'shows the receipt while a decision is the latest thing on the thread' do
      request = request_sent
      reply(request, 'rejected')
      travel_to(soon) { expect(step_for(request).panel).to eq(:receipt) }
    end

    it 'asks the requester to act once they have written since the decision' do
      request = request_sent
      reply(request, 'rejected')
      follow_up(request)
      travel_to(soon) { expect(step_for(request).panel).to eq(:act) }
    end

    it 'shows the receipt for a reply that has only just come' do
      request = request_sent
      reply(request, 'waiting_response')
      travel_to(soon) do
        expect(step_for(request).panel).to eq(:waiting)
        expect(step_for(request, arrived: true).panel).to eq(:receipt)
      end
    end

    it 'is closed once marked complete, and looks for no reply' do
      request = request_sent
      reply(request, 'successful')
      close(request)
      travel_to(soon) do
        step = step_for(request)
        expect(step.panel).to eq(:closed)
        expect(step.latest_reply).to be_nil
      end
    end

    it 'is done when nothing is expected and there is no reply to show' do
      request = request_sent
      travel_to(start + 1.day) do
        request.set_described_state('user_withdrawn')
      end
      travel_to(soon) { expect(step_for(request).panel).to eq(:done) }
    end
  end

  describe '#review_by' do
    it 'is the next action’s date when that is to ask for a review' do
      request = request_sent
      reply(request, 'rejected')
      travel_to(soon) do
        step = step_for(request)
        expect(step.action.kind).to eq(:ask_review)
        expect(step.review_by).to eq(step.action.date)
        expect(step.review_coming_up?).to be(true)
      end
    end

    it 'is the reply’s own review date while its status isn’t set' do
      request = request_sent
      delivered(request)
      travel_to(soon) do
        step = step_for(request)
        expect(step.review_by).to eq(step.latest_reply.review_by)
        expect(step.review_by).to be >= soon.to_date
      end
    end

    it 'is nothing for a reply that has only just come' do
      request = request_sent
      reply(request, 'waiting_response')
      travel_to(soon) do
        step = step_for(request, arrived: true)
        expect(step.review_by).to be_nil
        expect(step.review_coming_up?).to be(false)
      end
    end
  end

  describe '#completable?' do
    it 'is true when every reply has been read and answered for' do
      request = request_sent
      reply(request, 'rejected')
      travel_to(soon) { expect(step_for(request).completable?).to be(true) }
    end

    it 'is false while a reply is unread or waits for its status' do
      request = request_sent
      message = reply(request, 'rejected')
      waiting = request_sent
      delivered(waiting)
      travel_to(soon) do
        expect(step_for(request, unread: [message]).completable?).to be(false)
        expect(step_for(waiting).completable?).to be(false)
      end
    end
  end

  describe '#decision' do
    it 'gives the decision in the words of its status' do
      request = request_sent
      reply(request, 'rejected')
      follow_up(request)
      travel_to(soon) do
        expect(step_for(request).decision).
          to eq(InfoRequest::State.short_description('rejected'))
      end
    end
  end

  describe '#reply_to_read' do
    it 'is the first unread reply, or else the latest' do
      request = request_sent
      first = reply(request, 'waiting_response')
      second = reply(request, 'waiting_response', at: start + 8.days)
      travel_to(soon) do
        expect(step_for(request, unread: [first]).reply_to_read).to eq(first)
        expect(step_for(request).reply_to_read).to eq(second)
        expect(step_for(request).last_response).to eq(second)
      end
    end
  end

  describe '#change_status?' do
    it 'is true only when the viewer has a status to choose' do
      request = request_sent
      travel_to(start + 2.days) do
        choices = { pending: ['waiting_response'], complete: [], other: [] }
        none = { pending: [], complete: [], other: [] }
        expect(step_for(request, status_choices: choices).change_status?).
          to be_truthy
        expect(step_for(request, status_choices: none).change_status?).
          to be_falsey
        expect(step_for(request).change_status?).to be_falsey
      end
    end
  end

  describe 'dates' do
    it 'writes a date out for a sentence, and shortly for a label' do
      request = request_sent
      travel_to(start + 2.days) do
        step = step_for(request)
        expect(step.long_date(Date.new(2026, 10, 5))).to eq('5 October')
        expect(step.short_date(Date.new(2026, 10, 5))).to eq('5 Oct')
        expect(step.short_date(Date.new(2027, 1, 4))).to eq('4 Jan 2027')
      end
    end
  end
end
