require 'spec_helper'

RSpec.describe 'Request deadlines' do
  # Monday 7 September 2026. Bank holidays come from the gov.uk data
  # (the holidays table is empty in tests): for FOI, 30 November 2026, St
  # Andrew's Day in Scotland, is not a working day (FOIA s.10(6)), nor are 25
  # and 28 December.
  let(:start) { Time.zone.parse('2026-09-07 10:00') }

  # These rules are checked against core's own statuses.
  include_context 'with incoming attention off'
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

  describe Deadlines::NextAction do
    it 'is the authority\'s response, due 20 working days after sending' do
      request = request_sent
      next_action = action(request, on: start + 1.day)

      expect(next_action.group).to eq(:awaiting_authority)
      expect(next_action.kind).to eq(:response)
      expect(next_action.date).to eq(Date.new(2026, 10, 5))
      expect(next_action.label).to eq('Response due')
    end

    it 'counts working days late once the response is overdue' do
      request = request_sent
      next_action = action(request, on: Date.new(2026, 10, 9))

      expect(next_action.label).to eq('Response overdue')
      expect(next_action.late_days).to eq(4)
      expect(next_action.detail).to eq('4 working days late')
    end

    it 'asks the requester to clarify when the authority asked them to' do
      request = request_sent
      reply(request, at: start + 3.days, state: 'waiting_clarification')
      next_action = action(request, on: start + 5.days)

      expect(next_action.group).to eq(:action_required)
      expect(next_action.kind).to eq(:clarify)
      expect(next_action.date).to eq((start + 3.days).to_date)
    end

    it 'offers an internal review for 40 working days after a refusal' do
      request = request_sent
      reply(request, at: Time.zone.parse('2026-09-28 10:00'), state: 'rejected')

      next_action = action(request, on: Date.new(2026, 10, 1))
      expect(next_action.kind).to eq(:ask_review)
      expect(next_action.group).to eq(:action_required)
      expect(next_action.date).to eq(Date.new(2026, 11, 23))

      expect(action(request, on: Date.new(2026, 11, 24))).to be_none
    end

    it 'gives the authority 20 working days for an FOI review and 40 under the EIR' do
      foi = request_sent
      reply(foi, at: start + 7.days, state: 'rejected')
      review_requested(foi, at: Time.zone.parse('2026-09-21 10:00'))
      expect(action(foi, on: Date.new(2026, 9, 22))).
        to have_attributes(kind: :review, date: Date.new(2026, 10, 19))

      eir = request_sent(law_used: 'eir')
      reply(eir, at: start + 7.days, state: 'rejected')
      review_requested(eir, at: Time.zone.parse('2026-09-21 10:00'))
      expect(action(eir, on: Date.new(2026, 9, 22)).date).
        to eq(Date.new(2026, 11, 16))
    end

    it 'gives the ICO\'s six weeks after a review is upheld, or the Commissioner\'s six months in Scotland' do
      request = request_sent
      reply(request, at: start + 7.days, state: 'rejected')
      review_requested(request, at: start + 10.days)
      reply(request, at: Time.zone.parse('2026-10-01 10:00'), state: 'rejected')

      ico = action(request, on: Date.new(2026, 10, 2))
      expect(ico).
        to have_attributes(kind: :regulator, date: Date.new(2026, 11, 12))
      expect(ico.label).to eq('The ICO asks for complaints by')

      request.public_body.update!(tag_string: 'scotland')
      sic = action(request, on: Date.new(2026, 10, 2))
      expect(sic.date).to eq(Date.new(2027, 4, 1))
      expect(sic.label).to eq('Apply to the Commissioner by')
    end

    it 'starts the regulator window from the review decision, not an acknowledgement of the review' do
      request = request_sent
      reply(request, at: start + 7.days, state: 'rejected')
      review_requested(request, at: start + 10.days)
      reply(request, at: start + 11.days, state: 'internal_review')
      expect(action(request, on: start + 12.days).kind).to eq(:review)

      reply(request, at: Time.zone.parse('2026-10-01 10:00'), state: 'rejected')
      expect(action(request, on: Date.new(2026, 10, 2))).
        to have_attributes(kind: :regulator, date: Date.new(2026, 11, 12))
      expect(action(request, on: Date.new(2026, 10, 2)).timeline.map(&:first)).
        to eq(['Request sent',
               'Response due',
               'Decision received',
               'Internal review requested',
               'Internal review due',
               'Review response received',
               'The ICO asks for complaints by'])
    end

    it 'has nothing pending once the information has been provided' do
      request = request_sent
      reply(request, at: start + 7.days, state: 'successful')

      expect(action(request, on: start + 8.days)).to be_none
    end
  end

  describe Deadlines::Adjustment do
    it 'writes a changed response date to core, which stops counting it overdue' do
      request = request_sent
      travel_to(Time.zone.parse('2026-10-08 10:00')) do
        expect(request.reload.calculate_status).
          to eq('waiting_response_overdue')

        Deadlines::Adjustment.apply!(request, stage: 'response', user: user,
                                              due_on: Date.new(2026, 11, 2),
                                              reason: 'public_interest')
        request.reload

        expect(request.date_response_required_by).to eq(Date.new(2026, 11, 2))
        expect(request.date_very_overdue_after).to eq(Date.new(2026, 12, 1))
        expect(request.calculate_status).to eq('waiting_response')
        expect(Deadlines::NextAction.for(request)).
          to have_attributes(late?: false, adjusted?: true)
      end
    end

    it 'restores the original dates' do
      request = request_sent
      original = [request.date_response_required_by,
                  request.date_very_overdue_after]
      Deadlines::Adjustment.apply!(request, stage: 'response', user: user,
                                            due_on: Date.new(2026, 11, 2),
                                            reason: 'fee_notice')
      Deadlines::Adjustment.clear!(request.reload, 'response')

      expect([request.reload.date_response_required_by,
              request.date_very_overdue_after]).
        to eq(original)
      expect(Deadlines::Adjustment.current(request, 'response')).to be_nil
    end

    it 'keeps the first original date when the date is changed twice' do
      request = request_sent
      Deadlines::Adjustment.apply!(request, stage: 'response',
                                            user: user,
                                            due_on: Date.new(2026, 11, 2),
                                            reason: 'public_interest')
      second = Deadlines::Adjustment.apply!(request.reload,
                                            stage: 'response',
                                            user: user,
                                            due_on: Date.new(2026, 11, 16),
                                            reason: 'agreed')

      expect(second.original_due_on).to eq(Date.new(2026, 10, 5))
      expect(Deadlines::Adjustment.active.where(info_request: request).count).
        to eq(1)
    end

    it 'stops applying once core restarts the clock itself' do
      request = request_sent
      adjustment = Deadlines::Adjustment.apply!(request,
                                                stage: 'response',
                                                user: user,
                                                due_on: Date.new(2026, 11, 2),
                                                reason: 'agreed')
      reply(request, at: start + 3.days, state: 'waiting_clarification')
      travel_to(start + 4.days) do
        FactoryBot.create(:new_information_followup,
                          info_request: request.reload)
      end
      request.reload

      expect(request.date_response_required_by).to eq(Date.new(2026, 10, 9))
      expect(adjustment.reload).to be_superseded
      expect(Deadlines::NextAction.for(request, today: start.to_date + 5)).
        to have_attributes(adjusted?: false, date: Date.new(2026, 10, 9))
    end

    it 'holds an internal review date without touching core\'s due dates' do
      request = request_sent
      reply(request, at: start + 7.days, state: 'rejected')
      review_requested(request, at: Time.zone.parse('2026-09-21 10:00'))
      before = request.date_response_required_by

      Deadlines::Adjustment.apply!(request, stage: 'review', user: user,
                                            due_on: Date.new(2026, 11, 16),
                                            reason: 'review_extension')

      expect(request.reload.date_response_required_by).to eq(before)
      expect(action(request, on: Date.new(2026, 10, 20))).
        to have_attributes(kind: :review, date: Date.new(2026,
                                                         11,
                                                         16), late?: false)
    end

    it 'refuses a date before the clock started, or a reason it does not know' do
      request = request_sent
      expect {
        Deadlines::Adjustment.apply!(request, stage: 'response',
                                              user: user,
                                              due_on: start.to_date - 1,
                                              reason: 'agreed')
      }.to raise_error(ActiveRecord::RecordInvalid)
      expect {
        Deadlines::Adjustment.apply!(request, stage: 'response',
                                              user: user,
                                              due_on: Date.new(2026, 11, 2),
                                              reason: 'whim')
      }.to raise_error(ActiveRecord::RecordInvalid)
      expect(request.reload.date_response_required_by).
        to eq(Date.new(2026, 10, 5))
    end
  end

  describe 'changing the deadline for asking for a review' do
    it 'counts from the decision and can be changed to the date in the authority’s letter' do
      request = request_sent
      reply(request, at: Time.zone.parse('2026-09-28 10:00'), state: 'rejected')
      expect(action(request, on: Date.new(2026, 10, 1))).
        to have_attributes(kind: :ask_review,
                           adjustable_stage: 'review_request')

      travel_to(Time.zone.parse('2026-10-01 10:00')) do
        Deadlines::Adjustment.apply!(request, stage: 'review_request',
                                              user: user,
                                              due_on: Date.new(2026, 12, 18),
                                              reason: 'authority_letter')
      end
      next_action = action(request, on: Date.new(2026, 11, 30))
      expect(next_action).
        to have_attributes(kind: :ask_review,
                           date: Date.new(2026, 12, 18),
                           adjusted?: true)
      expect(request.reload.date_response_required_by).
        to eq(Date.new(2026, 10, 5))
    end

    it 'stops applying when a new decision arrives' do
      request = request_sent
      reply(request, at: Time.zone.parse('2026-09-28 10:00'), state: 'rejected')
      adjustment = travel_to(Time.zone.parse('2026-10-01 10:00')) do
        Deadlines::Adjustment.apply!(request, stage: 'review_request',
                                              user: user,
                                              due_on: Date.new(2026, 12, 18),
                                              reason: 'agreed')
      end
      reply(request, at: Time.zone.parse('2026-10-05 10:00'),
                     state: 'partially_successful')

      expect(adjustment.reload).to be_superseded
      expect(action(request, on: Date.new(2026, 10, 6)).date).
        to eq(Date.new(2026, 12, 1))
    end
  end

  describe Deadlines::Closure do
    it 'sets the final status through core and takes the request off the lists' do
      request = request_sent
      reply(request, at: start + 7.days, state: 'rejected')
      # A day inside the time to ask for a review, so it is the closure that
      # takes the request off the lists and not the time running out.
      today = (start + 8.days).to_date
      listed = Deadlines::Overview.lists(user, today: today)
      expect(listed[:action_required].map(&:request)).to include(request)

      closure = Deadlines::Closure.close!(
        request.reload,
        user: user,
        final_state: 'rejected',
        last_event_id: request.info_request_events.maximum(:id)
      )
      request.reload

      expect(closure).to be_persisted
      expect(request.described_state).to eq('rejected')
      expect(request.info_request_events.last).
        to have_attributes(event_type: 'status_update',
                           described_state: 'rejected')
      expect(Deadlines::NextAction.for(request, today: today)).
        to have_attributes(none?: true, closed?: true)
      lists = Deadlines::Overview.lists(user, today: today)
      expect(lists.values.flatten.map(&:request)).not_to include(request)
    end

    it 'can give a different final status from the current one' do
      request = request_sent
      Deadlines::Closure.close!(
        request,
        user: user,
        final_state: 'user_withdrawn',
        last_event_id: request.info_request_events.maximum(:id)
      )
      expect(request.reload.calculate_status).to eq('user_withdrawn')
    end

    it 'changes nothing if the request has moved on since the page was loaded' do
      request = request_sent
      seen = request.info_request_events.maximum(:id)
      reply(request, at: start + 3.days, state: 'waiting_response')

      expect {
        Deadlines::Closure.close!(request.reload, user: user,
                                                  final_state: 'successful',
                                                  last_event_id: seen)
      }.to raise_error(Deadlines::Closure::Stale)
      expect(request.reload.described_state).to eq('waiting_response')
      expect(Deadlines::Closure.count).to eq(0)
    end

    it 'is reopened by any later correspondence' do
      request = request_sent
      reply(request, at: start + 7.days, state: 'rejected')
      Deadlines::Closure.close!(
        request.reload,
        user: user,
        final_state: 'rejected',
        last_event_id: request.info_request_events.maximum(:id)
      )
      travel_to(start + 9.days) do
        message = FactoryBot.create(:incoming_message, info_request: request)
        request.log_event('response', incoming_message_id: message.id)
        request.update!(awaiting_description: true)
      end

      next_action = action(request, on: start + 10.days)
      expect(next_action).not_to be_closed
      expect(next_action.kind).to eq(:read_reply)
    end

    it 'refuses a status that is not final' do
      request = request_sent
      expect {
        Deadlines::Closure.close!(
          request,
          user: user,
          final_state: 'waiting_response',
          last_event_id: request.info_request_events.maximum(:id)
        )
      }.to raise_error(ArgumentError)
    end
  end

  describe 'review fixes' do
    def auto_routine_reply(request, at:)
      travel_to(at) do
        message = FactoryBot.create(:incoming_message, info_request: request)
        request.log_event('response', incoming_message_id: message.id)
        request.update!(awaiting_description: true)
        IncomingAttention::Classification.automatically do
          request.reload.set_described_state(request.described_state)
        end
        IncomingAttention::Prediction.create!(incoming_message: message,
                                              info_request: request,
                                              status: 'complete',
                                              route: 'SKIP',
                                              needs_check: false,
                                              eligible: true,
                                              restrictions: [],
                                              attempts: 1,
                                              auto_classified: true)
      end
    end

    it 'does not restart the review window for a routine reply classified automatically' do
      request = request_sent
      reply(request, at: Time.zone.parse('2026-09-28 10:00'), state: 'rejected')
      auto_routine_reply(request, at: Time.zone.parse('2026-10-20 10:00'))

      expect(action(request, on: Date.new(2026, 10, 21)).date).
        to eq(Date.new(2026, 11, 23))

      travel_to(Time.zone.parse('2026-10-22 10:00')) do
        request.reload.log_event('status_update',
                                 user_id: user.id,
                                 old_described_state: 'rejected',
                                 described_state: 'rejected')
        request.reload.set_described_state('rejected', user)
      end
      expect(action(request, on: Date.new(2026, 10, 23)).date).
        to eq(Date.new(2026, 12, 16))
    end

    it 'says overdue on the day after the due date, even at a weekend' do
      request = request_sent(at: Time.zone.parse('2026-09-11 10:00'))
      expect(request.reload.date_response_required_by).
        to eq(Date.new(2026, 10, 9))

      saturday = action(request, on: Date.new(2026, 10, 10))
      expect(saturday).
        to have_attributes(late?: true,
                           late_days: 0,
                           label: 'Response overdue',
                           detail: nil)
      travel_to(Time.zone.parse('2026-10-10 10:00')) {
        expect(request.reload.calculate_status).
          to eq('waiting_response_overdue')
      }
    end

    it 'only accepts the reasons offered for each date' do
      request = request_sent
      reply(request, at: Time.zone.parse('2026-09-28 10:00'), state: 'rejected')
      travel_to(Time.zone.parse('2026-10-01 10:00')) do
        expect {
          Deadlines::Adjustment.apply!(request, stage: 'review_request',
                                                user: user,
                                                due_on: Date.new(2026, 12, 18),
                                                reason: 'fee_notice')
        }.to raise_error(ActiveRecord::RecordInvalid)
      end
    end

    it 'checks the stage under the lock, so a stale stage changes nothing' do
      request = request_sent
      reply(request, at: start + 3.days, state: 'successful')
      expect {
        Deadlines::Adjustment.apply!(request.reload,
                                     stage: 'response',
                                     user: user,
                                     due_on: Date.new(2026, 11, 2),
                                     reason: 'agreed')
      }.to raise_error(ArgumentError)
      expect(request.reload.date_response_required_by).
        to eq(Date.new(2026, 10, 5))
    end

    it 'will not mark complete while a reply is unread' do
      request = request_sent
      travel_to(start + 3.days) do
        message = FactoryBot.create(:incoming_message, info_request: request)
        request.log_event('response', incoming_message_id: message.id)
        request.update!(awaiting_description: true)
      end
      expect {
        Deadlines::Closure.close!(
          request.reload,
          user: user,
          final_state: 'successful',
          last_event_id: request.info_request_events.maximum(:id)
        )
      }.to raise_error(Deadlines::Closure::UnreadReplies)
      expect(request.reload.described_state).to eq('waiting_response')
    end

    context 'with incoming attention on' do
      include_context 'with incoming attention off', true

      it 'will not mark complete while a reply is still being checked, though the request shows as awaiting' do
        request = request_sent
        travel_to(start + 3.days) do
          message = FactoryBot.create(:incoming_message, info_request: request)
          request.log_event('response', incoming_message_id: message.id)
          request.update!(awaiting_description: true)
          # The receipt hook may already have made the pending row.
          IncomingAttention::Prediction.
            find_or_initialize_by(incoming_message_id: message.id).
            update!(info_request: request,
                    status: 'pending',
                    restrictions: [],
                    attempts: 0)
        end

        expect(action(request, on: start + 4.days).group).
          to eq(:awaiting_authority)
        expect {
          Deadlines::Closure.close!(
            request.reload,
            user: user,
            final_state: 'successful',
            last_event_id: request.info_request_events.maximum(:id)
          )
        }.to raise_error(Deadlines::Closure::UnreadReplies)
        expect(
          IncomingAttention::Prediction.where(human_reviewed_at: nil).count
        ).to eq(1)
      end
    end

    it 'reopens on a failed send and shows the delivery problem' do
      request = request_sent
      reply(request, at: start + 7.days, state: 'rejected')
      Deadlines::Closure.close!(
        request.reload,
        user: user,
        final_state: 'rejected',
        last_event_id: request.info_request_events.maximum(:id)
      )
      travel_to(start + 9.days) do
        followup = OutgoingMessage.create!(info_request: request.reload,
                                           status: 'ready',
                                           message_type: 'followup',
                                           what_doing: 'normal_sort',
                                           body: "Dear Authority,\n\nA " \
                                                 "follow-up.\n\nYours " \
                                                 "faithfully,\n\n#{user.name}")
        followup.record_email_failure('The mail server refused it')
      end

      next_action = action(request, on: start + 10.days)
      expect(next_action).not_to be_closed
      expect(next_action.kind).to eq(:delivery)
    end

    it 'expects a reply once a failed follow-up has been resent, even if the status was never restored' do
      request = request_sent
      followup = travel_to(start + 3.days) do
        OutgoingMessage.create!(info_request: request.reload,
                                status: 'ready',
                                message_type: 'followup',
                                what_doing: 'normal_sort',
                                body: "Dear Authority,\n\nA " \
                                      "follow-up.\n\nYours " \
                                      "faithfully,\n\n#{user.name}").
          tap { |message|
            message.record_email_failure('The mail server refused it')
          }
      end
      expect(action(request, on: start + 4.days).kind).to eq(:delivery)

      travel_to(start + 5.days) {
        followup.reload.record_email_delivery(request.public_body.request_email,
                                              '<resend@synthetic.test>',
                                              'resent')
      }
      # DeliveryTransitions restores the status; an older resend may still be at
      # error_message.
      expect(request.reload.described_state).to eq('waiting_response')
      travel_to(start + 5.days + 1.hour) do
        IncomingAttention::Classification.automatically do
          request.set_described_state('error_message')
        end
      end
      expect(action(request, on: start + 6.days)).
        to have_attributes(kind: :follow_up, group: :awaiting_authority,
                           date: (start + 5.days).to_date)
    end

    it 'expects a reply after a follow-up to a request marked complete' do
      request = request_sent
      reply(request, at: start + 7.days, state: 'successful')
      Deadlines::Closure.close!(
        request.reload,
        user: user,
        final_state: 'successful',
        last_event_id: request.info_request_events.maximum(:id)
      )
      travel_to(start + 9.days) {
        FactoryBot.create(:new_information_followup,
                          info_request: request.reload)
      }

      next_action = action(request, on: start + 10.days)
      expect(next_action).
        to have_attributes(kind: :follow_up,
                           group: :awaiting_authority,
                           date: (start + 9.days).to_date)
      expect(next_action.detail).to eq('awaiting a reply')
    end

    it 'leaves requests the user can no longer read out of the dashboard lists' do
      request = request_sent
      expect(Deadlines::Overview.actions(user).map(&:request)).
        to include(request)
      request.update!(prominence: 'hidden')
      expect(Deadlines::Overview.actions(user).map(&:request)).
        not_to include(request)
    end

    it 'keeps the record when the acting user is deleted' do
      request = request_sent
      admin = FactoryBot.create(:admin_user)
      adjustment = Deadlines::Adjustment.apply!(request,
                                                stage: 'response',
                                                user: admin,
                                                due_on: Date.new(2026, 11, 2),
                                                reason: 'agreed')
      ActiveRecord::Base.connection.
        execute("DELETE FROM users_roles WHERE user_id = #{admin.id}")
      ActiveRecord::Base.connection.
        execute("DELETE FROM users WHERE id = #{admin.id}")
      expect(adjustment.reload.user_id).to be_nil
      expect(adjustment.info_request).to eq(request)
    end
  end

  describe 'sorting the request list by next deadline' do
    it 'puts the most pressing deadline first and finished requests last' do
      done = request_sent(at: start - 30.days)
      reply(done, at: start - 5.days, state: 'successful')
      later = request_sent(at: start)
      sooner = request_sent(at: start - 7.days)
      [done, later, sooner].each { |r| AlaveteliPro::RequestSummary.create_or_update_from(r) }

      filter = AlaveteliPro::RequestFilter.new
      filter.update(order: 'next_deadline')
      travel_to(start + 1.day) do
        expect(filter.results(user).map(&:summarisable)).
          to eq([sooner, later, done])
      end
      expect(filter.order_options.map(&:last)).to include('next_deadline')
    end
  end
end
