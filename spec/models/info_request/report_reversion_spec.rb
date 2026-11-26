require 'spec_helper'

RSpec.describe InfoRequest, 'reverting a report' do
  let(:reporter) { FactoryBot.create(:user) }
  let(:admin) { FactoryBot.create(:admin_user) }
  let(:info_request) { FactoryBot.create(:info_request) }

  def classify(request, state)
    request.log_event('status_update',
                      user_id: request.user.id,
                      old_described_state: request.described_state,
                      described_state: state)
    request.set_described_state(state, request.user)
  end

  def admin_edit(request, state)
    old_state = request.described_state
    request.update!(described_state: state)
    request.log_event('edit', editor: 'an-admin',
                              old_described_state: old_state,
                              described_state: state)
  end

  # Edit metadata always submits described_state even when unchanged.
  def admin_title_edit(request)
    request.log_event('edit', editor: 'an-admin',
                              old_title: request.title,
                              title: "#{request.title} (edited)",
                              old_described_state: request.described_state,
                              described_state: request.described_state)
  end

  def revert(request, report_event_id: request.last_report_event&.id)
    request.revert_report!(editor: admin.url_name,
                           report_event_id: report_event_id)
  end

  def reply(request)
    message = FactoryBot.create(:incoming_message, info_request: request)
    request.log_event('response', incoming_message_id: message.id)
    request.update!(awaiting_description: true)
    message
  end

  describe '#reported?' do
    it 'is true for a request reported for attention' do
      info_request.report!('Vexatious', 'Please check', reporter)
      expect(info_request).to be_reported
    end

    it 'is true for a request classified as needing an admin' do
      classify(info_request, 'requires_admin')
      expect(info_request).to be_reported
    end

    it 'is false for a request at error_message, which is not a report' do
      classify(info_request, 'error_message')
      expect(info_request).not_to be_reported
    end

    it 'is false for an unreported request' do
      expect(info_request).not_to be_reported
    end
  end

  describe '#classification_before_report' do
    it 'is the classification before the report' do
      classify(info_request, 'successful')
      info_request.report!('Vexatious', 'Please check', reporter)

      expect(info_request.classification_before_report).
        to eq('successful')
    end

    it 'skips events that set no classification, before and after it' do
      classify(info_request, 'successful')
      info_request.log_event('overdue', {})
      info_request.report!('Vexatious', 'Please check', reporter)
      info_request.log_event('very_overdue', {})

      expect(info_request.reload.classification_before_report).
        to eq('successful')
    end

    it 'skips repeated reports' do
      classify(info_request, 'successful')
      classify(info_request, 'requires_admin')
      info_request.report!('Vexatious', 'Please check', reporter)

      expect(info_request.classification_before_report).
        to eq('successful')
    end

    it 'takes a classification made between two reports' do
      info_request.report!('Vexatious', 'First', reporter)
      classify(info_request, 'partially_successful')
      info_request.report!('Vexatious', 'Second', reporter)

      expect(info_request.classification_before_report).
        to eq('partially_successful')
    end

    it 'takes a status an admin set in Edit metadata between two reports' do
      info_request.report!('Vexatious', 'First', reporter)
      admin_edit(info_request, 'successful')
      info_request.report!('Vexatious', 'Second', reporter)

      expect(info_request.reload.classification_before_report).
        to eq('successful')
    end

    it 'counts a report an admin set in Edit metadata' do
      classify(info_request, 'successful')
      info_request.report!('Vexatious', 'First', reporter)
      admin_edit(info_request, 'partially_successful')
      admin_edit(info_request, 'requires_admin')

      info_request.reload
      expect(info_request.last_report_event.event_type).to eq('edit')
      expect(info_request.classification_before_report).
        to eq('partially_successful')
    end

    it 'ignores an edit that left the status alone, after the report' do
      classify(info_request, 'successful')
      info_request.report!('Vexatious', 'Please check', reporter)
      admin_title_edit(info_request)

      info_request.reload
      expect(info_request.last_report_event.event_type).
        to eq('report_request')
      expect(info_request.classification_before_report).to eq('successful')
    end

    it 'is nil when the request was never reported' do
      expect(info_request.classification_before_report).to be_nil
    end

    it 'is nil when nothing before the report has a classification' do
      info_request.info_request_events.update_all(described_state: nil)
      info_request.report!('Vexatious', 'Please check', reporter)

      expect(info_request.reload.classification_before_report).to be_nil
    end
  end

  describe '#replies_classified_by_report' do
    it 'lists replies received between that status and the report' do
      classify(info_request, 'waiting_response')
      reply(info_request)
      info_request.report!('Vexatious', 'Please check', reporter)

      expect(info_request.replies_classified_by_report.map(&:event_type)).
        to eq(['response'])
    end

    it 'ignores an edit that left the status alone, after the reply' do
      classify(info_request, 'waiting_response')
      reply(info_request)
      admin_title_edit(info_request)
      info_request.report!('Vexatious', 'Please check', reporter)

      expect(info_request.reload.replies_classified_by_report.size).to eq(1)
    end

    it 'is empty when the status before the report covered every reply' do
      reply(info_request)
      classify(info_request, 'successful')
      info_request.report!('Vexatious', 'Please check', reporter)

      expect(info_request.replies_classified_by_report).to be_empty
    end
  end

  describe '#last_report_event' do
    it 'is the latest event that reported the request' do
      classify(info_request, 'requires_admin')
      info_request.report!('Vexatious', 'Please check', reporter)

      event = info_request.last_report_event
      expect(event.event_type).to eq('report_request')
      expect(event.params[:message]).to eq('Please check')
    end
  end

  describe '#revert_report!' do
    context 'with a reported request' do
      before do
        classify(info_request, 'successful')
        info_request.report!('Vexatious', 'Please check', reporter)
      end

      it 'puts back the classification from before the report' do
        revert(info_request)

        info_request.reload
        expect(info_request.described_state).to eq('successful')
        expect(info_request.awaiting_description).to be(false)
        expect(info_request.calculate_status).to eq('successful')
      end

      it 'logs the admin, both states and the report' do
        report = info_request.last_report_event
        revert(info_request)

        event = info_request.reload.last_event
        expect(event.event_type).to eq('status_update')
        expect(event.described_state).to eq('successful')
        expect(event.params).to eq(editor: admin.url_name,
                                   old_described_state: 'attention_requested',
                                   described_state: 'successful',
                                   report_event_id: report.id)
      end

      it 'keeps the report in the history' do
        reports = info_request.info_request_events.
                  where(event_type: 'report_request')
        expect { revert(info_request) }.
          not_to(change { reports.count })
        expect(info_request.reload.attention_requested).to be(true)
      end

      it 'sends no mail' do
        expect { revert(info_request) }.
          not_to(change { ActionMailer::Base.deliveries.size })
      end

      it 'can be reported and reverted again' do
        revert(info_request)
        info_request.report!('Vexatious', 'Again', reporter)
        revert(info_request)

        expect(info_request.reload.described_state).to eq('successful')
      end
    end

    it 'leaves a reply classified before the report its classification' do
      reply(info_request)
      classify(info_request, 'successful')
      info_request.report!('Vexatious', 'Please check', reporter)
      response = info_request.info_request_events.
                 find_by(event_type: 'response')
      expect(response.reload.calculated_state).to eq('successful')

      revert(info_request)

      expect(response.reload.calculated_state).to eq('successful')
    end

    it 'leaves a reply the report classified counted, with the restored status' do
      classify(info_request, 'waiting_response')
      message = reply(info_request)
      info_request.report!('Vexatious', 'Please check', reporter)

      revert(info_request)

      info_request.reload
      expect(info_request.described_state).to eq('waiting_response')
      expect(info_request.awaiting_description).to be(false)
      expect(message.response_event.reload.calculated_state).
        to eq('waiting_response')
    end

    it 'reverts to a status an admin set in Edit metadata' do
      info_request.report!('Vexatious', 'First', reporter)
      admin_edit(info_request, 'successful')
      info_request.report!('Vexatious', 'Second', reporter)

      revert(info_request)

      expect(info_request.reload.described_state).to eq('successful')
    end

    it 'reverts a request classified as needing an admin' do
      classify(info_request, 'waiting_clarification')
      classify(info_request, 'requires_admin')

      revert(info_request)

      expect(info_request.reload.described_state).
        to eq('waiting_clarification')
    end

    it 'refuses a report other than the one the admin saw' do
      classify(info_request, 'successful')
      info_request.report!('Vexatious', 'First', reporter)
      seen = info_request.last_report_event.id
      revert(info_request)
      classify(info_request, 'partially_successful')
      info_request.report!('Vexatious', 'Second', reporter)

      expect { revert(info_request, report_event_id: seen) }.
        to raise_error(InfoRequest::StaleReportError)
      expect(info_request.reload.described_state).to eq('attention_requested')
    end

    shared_examples 'changes nothing' do |error|
      it "raises #{error.name.demodulize} and changes nothing" do
        state = info_request.reload.described_state
        events = info_request.info_request_events.count

        expect { revert(info_request) }.
          to raise_error(error)

        expect(info_request.reload.described_state).to eq(state)
        expect(info_request.info_request_events.count).to eq(events)
      end
    end

    context 'with a request that is not reported' do
      before { classify(info_request, 'successful') }

      include_examples 'changes nothing', InfoRequest::NotReportedError
    end

    context 'with nothing before the report to go back to' do
      before do
        info_request.info_request_events.update_all(described_state: nil)
        info_request.report!('Vexatious', 'Please check', reporter)
      end

      include_examples 'changes nothing',
                       InfoRequest::NoClassificationBeforeReportError
    end

    context 'with a reply that arrived after the report' do
      before do
        classify(info_request, 'successful')
        info_request.report!('Vexatious', 'Please check', reporter)
        reply(info_request)
      end

      include_examples 'changes nothing', InfoRequest::UnreadRepliesError

      it 'leaves the reply waiting for the requester' do
        expect { revert(info_request) }.
          to raise_error(InfoRequest::UnreadRepliesError)
        expect(info_request.reload.awaiting_description).to be(true)
      end
    end

    context 'with a clarification sent since the report' do
      before do
        classify(info_request, 'waiting_clarification')
        info_request.report!('Vexatious', 'Please check', reporter)
        info_request.log_event('followup_sent', {})
      end

      include_examples 'changes nothing', InfoRequest::SentSinceReportError
    end

    context 'with a clarification sent between two reports' do
      before do
        classify(info_request, 'waiting_clarification')
        info_request.report!('Vexatious', 'Please check', reporter)
        info_request.log_event('followup_sent', {})
        classify(info_request, 'requires_admin')
      end

      include_examples 'changes nothing', InfoRequest::SentSinceReportError
    end

    it 'reverts when a follow-up since the report left the status current' do
      classify(info_request, 'waiting_response')
      info_request.report!('Vexatious', 'Please check', reporter)
      info_request.log_event('followup_sent', {})

      revert(info_request)

      expect(info_request.reload.described_state).to eq('waiting_response')
    end

    context 'with incoming attention on' do
      include_context 'with incoming attention off', true

      def prediction_for(message, **attributes)
        IncomingAttention::Prediction.
          find_or_initialize_by(incoming_message_id: message.id).
          tap do |prediction|
            prediction.update!(info_request: message.info_request,
                               status: 'pending',
                               restrictions: [],
                               attempts: 0,
                               **attributes)
          end
      end

      it 'refuses while a reply classified automatically awaits review' do
        classify(info_request, 'successful')
        info_request.report!('Vexatious', 'Please check', reporter)
        message = reply(info_request)
        prediction = prediction_for(message, auto_classified: true)
        info_request.update!(awaiting_description: false)

        expect(info_request.report_reversion_blocker).
          to be_a(InfoRequest::UnreadRepliesError)
        expect { revert(info_request) }.
          to raise_error(InfoRequest::UnreadRepliesError)
        expect(prediction.reload.human_reviewed_at).to be_nil
        expect(info_request.reload.described_state).
          to eq('attention_requested')
      end

      it 'keeps the review a reply had before the report' do
        message = reply(info_request)
        prediction = prediction_for(message)
        classify(info_request, 'successful')
        reviewed_at = prediction.reload.human_reviewed_at
        info_request.report!('Vexatious', 'Please check', reporter)

        revert(info_request)

        expect(info_request.reload.described_state).to eq('successful')
        expect(prediction.reload.human_reviewed_at).to be_present
        expect(prediction.human_reviewed_at).to be >= reviewed_at
        messages = IncomingMessage.where(info_request_id: info_request.id)
        expect(IncomingAttention::Effective.unresolved(messages)).to be_empty
      end

      def routine_reply(request)
        message = reply(request)
        prediction_for(message, attention_override: 'routine')
        IncomingAttention::Classification.apply(request.reload)
        message
      end

      it 'keeps the report, not a routine reply that repeated it' do
        classify(info_request, 'successful')
        info_request.report!('Vexatious', 'Please check', reporter)
        message = routine_reply(info_request)
        expect(message.response_event.reload.described_state).
          to eq('attention_requested')

        info_request.reload
        expect(info_request.last_report_event.event_type).
          to eq('report_request')
        expect(info_request.report_reversion_blocker).
          to be_a(InfoRequest::UnreadRepliesError)

        IncomingAttention::Prediction.for_message(message).
          update!(human_reviewed_at: Time.zone.now)
        report = info_request.last_report_event
        revert(info_request)

        expect(info_request.reload.described_state).to eq('successful')
        expect(info_request.last_event.params[:report_event_id]).
          to eq(report.id)
      end

      it 'does not make a routine reply before the report a decision' do
        classify(info_request, 'rejected')
        message = routine_reply(info_request)
        info_request.report!('Vexatious', 'Please check', reporter)

        revert(info_request)

        expect(info_request.reload.described_state).to eq('rejected')
        expect(Deadlines::Stage.decision?(info_request,
                                          message.response_event.reload)).
          to be(false)
      end

      it 'does not make a routine reply a decision through requires_admin' do
        classify(info_request, 'rejected')
        message = routine_reply(info_request)
        classify(info_request.reload, 'requires_admin')

        revert(info_request)

        expect(info_request.reload.described_state).to eq('rejected')
        expect(Deadlines::Stage.decision?(info_request,
                                          message.response_event.reload)).
          to be(false)
      end
    end
  end

  describe '#report_reversion_blocker' do
    it 'is nil when the report can be reverted' do
      classify(info_request, 'successful')
      info_request.report!('Vexatious', 'Please check', reporter)

      expect(info_request.report_reversion_blocker).to be_nil
    end

    it 'says why when it cannot' do
      expect(info_request.report_reversion_blocker.message).
        to eq('This request is not reported, so there is no report to revert.')
    end
  end
end
