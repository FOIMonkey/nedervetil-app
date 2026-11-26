require 'spec_helper'

RSpec.describe Deadlines::Overview do
  include_context 'with incoming attention off' if defined?(IncomingAttention::Config)
  let(:user) { FactoryBot.create(:pro_user, trusted: true) }
  let(:start) { Time.zone.parse('2026-09-07 10:00') }
  let(:today) { Date.new(2026, 10, 1) }

  def request_sent(**attributes)
    request = travel_to(start) {
      FactoryBot.create(:info_request, user: user, **attributes)
    }
    if attributes[:date_response_required_by]
      request.update!(
        date_response_required_by: attributes[:date_response_required_by]
      )
    end
    request
  end

  def reply(request, state, at: start + 7.days)
    travel_to(at) do
      message = FactoryBot.create(:incoming_message, info_request: request)
      request.log_event('response', incoming_message_id: message.id)
      request.reload.set_described_state(state)
    end
  end

  def close(request)
    Deadlines::Closure.close!(
      request.reload,
      user: user,
      final_state: 'successful',
      last_event_id: request.info_request_events.maximum(:id)
    )
  end

  def signature(action)
    [action.request.id,
     action.kind,
     action.group,
     action.date,
     action.regime,
     action.adjustment&.id]
  end

  # The single-request calculation is the authority for the bulk result.
  def expect_current_actions
    ability = Ability.new(user)
    expected = user.info_requests.where.not(
      described_state: nil
    ).filter_map do |request|
      next unless ability.can?(:read, request)

      action = Deadlines::NextAction.for(request, today: today)
      signature(action) unless action.none?
    end
    actual = described_class.actions(user, today: today).map { |action|
                                       signature(action)
                                     }
    expect(actual).to match_array(expected)
  end

  it 'keeps complete counts and date/id ordering across private and hidden requests' do
    requests = Array.new(10) { |i|
      request_sent(date_response_required_by: today + 10 - i)
    }
    private_request = request_sent(prominence: 'requester_only',
                                   date_response_required_by: today - 1)
    second_private = request_sent(prominence: 'requester_only',
                                  date_response_required_by: today + 1)
    request_sent(prominence: 'hidden', date_response_required_by: today - 2)
    request_sent(user: FactoryBot.create(:user),
                 prominence: 'requester_only',
                 date_response_required_by: today - 3)
    lists = described_class.lists(user, today: today)

    expect(lists[:action_required]).to be_empty
    expect(lists[:awaiting_authority].size).to eq(12)
    expect(lists[:awaiting_authority].map { |action| action.request.id }).
      to eq([private_request.id,
             requests.last.id,
             second_private.id,
             *requests[0...-1].reverse.map(&:id)])

    private_request.update!(prominence: 'hidden')
    expect(described_class.lists(user, today: today)[:awaiting_authority].size).
      to eq(11)
    expect_current_actions
  end

  it 'does not instantiate event histories for simple requests with stored due dates' do
    3.times { request_sent }
    completed = request_sent
    reply(completed, 'successful')
    instantiated = 0
    subscriber = ActiveSupport::Notifications.subscribe(
      'instantiation.active_record'
    ) do |*, payload|
      if payload[:class_name] == 'InfoRequestEvent'
        instantiated += payload[:record_count]
      end
    end

    expect(described_class.lists(user, today: today)[:awaiting_authority].size).
      to eq(3)
    expect(instantiated).to eq(0)
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber) if subscriber
  end

  it 'retains histories for adjustments, closures, reopening, reviews and legacy missing dates' do
    adjusted = request_sent
    Deadlines::Adjustment.apply!(adjusted, stage: 'response', user: user,
                                           due_on: today + 20, reason: 'agreed')
    closed = request_sent
    close(closed)
    reopened = request_sent
    close(reopened)
    travel_to(start + 9.days) {
      FactoryBot.create(:new_information_followup,
                        info_request: reopened.reload)
    }
    review = request_sent(law_used: 'eir')
    reply(review, 'rejected')
    travel_to(start + 10.days) {
      FactoryBot.create(:internal_review_request, info_request: review.reload)
    }
    legacy = request_sent
    legacy.update_columns(date_response_required_by: nil,
                          date_very_overdue_after: nil)

    expect_current_actions
    actions = described_class.actions(user, today: today).index_by { |action|
                                        action.request.id
                                      }
    expect(actions.keys).not_to include(closed.id)
    expect(actions.fetch(adjusted.id).date).to eq(today + 20)
    expect(actions.fetch(reopened.id).kind).to eq(:follow_up)
    expect(actions.fetch(review.id).kind).to eq(:review)
    expect(actions.fetch(legacy.id).date).to eq(Date.new(2026, 10, 5))
  end

  it 'keeps actionable replies and puts undated actions last without retaining stale results' do
    partial = request_sent
    reply(partial, 'partially_successful')
    clarification = request_sent
    reply(clarification, 'waiting_clarification')
    undated = request_sent
    undated.update!(described_state: 'waiting_clarification')

    expect_current_actions
    lists = described_class.lists(user, today: today)
    expect(lists[:action_required].map { |action| action.request.id }).to eq(
      [clarification.id, partial.id, undated.id]
    )
    # The review-request window expires without any database write.
    later = described_class.lists(user, today: today + 100)[:action_required]
    expect(later.map { |action| action.request.id }).
      to eq([clarification.id, undated.id])
    reply(clarification, 'successful', at: start + 12.days)
    expect(described_class.lists(user, today: today)[:action_required].size).
      to eq(2)
  end

  it 'uses fresh correspondence and attention state after a previously simple response deadline' do
    request = request_sent
    expect(described_class.actions(user, today: today).first.kind).
      to eq(:response)
    travel_to(start + 8.days) do
      message = FactoryBot.create(:incoming_message, info_request: request)
      request.log_event('response', incoming_message_id: message.id)
      request.update!(awaiting_description: true)
    end
    expect_current_actions
    expect(described_class.actions(user, today: today).first.kind).
      to eq(:read_reply)
    expect(described_class.lists(user, today: today).values.flatten).to be_empty
  end

  context 'with classification presentation enabled' do
    include_context 'with incoming attention off', true if defined?(IncomingAttention::Config)
    it 'preserves the next action for a reply still awaiting classification' do
      request = request_sent
      travel_to(start + 8.days) do
        message = FactoryBot.create(:incoming_message, info_request: request)
        request.log_event('response', incoming_message_id: message.id)
        request.update!(awaiting_description: true)
      end
      expect_current_actions
    end
  end
end
