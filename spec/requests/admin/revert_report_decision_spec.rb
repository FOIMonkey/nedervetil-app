require 'spec_helper'

# A refusal the requester classified stays the decision a review counts from
# while the request is reported, after a routine reply arrives, and after an
# admin reverts the report.
RSpec.describe 'The decision through a report and its reversion',
               type: :request do
  include_context 'with incoming attention off', true

  let(:admin) { FactoryBot.create(:admin_user) }
  let(:requester) { FactoryBot.create(:user) }
  let(:info_request) do
    request = FactoryBot.create(:info_request, user: requester)
    request.set_described_state('waiting_response')
    request
  end

  def reply_to(request)
    message = FactoryBot.create(:incoming_message, info_request: request)
    request.log_event('response', incoming_message_id: message.id)
    request.update!(awaiting_description: true)
    message
  end

  def routine(message)
    IncomingAttention::Prediction.
      find_or_initialize_by(incoming_message_id: message.id).
      update!(info_request: message.info_request, status: 'pending',
              restrictions: [], attempts: 0, attention_override: 'routine')
  end

  let!(:decision) do
    message = reply_to(info_request)
    sign_in(requester)
    post classifications_path(url_title: info_request.url_title), params: {
      classification: { described_state: 'rejected' },
      last_info_request_event_id:
        info_request.reload.last_event_id_needing_description
    }
    expect(info_request.reload.described_state).to eq('rejected')
    message.response_event
  end

  let!(:routine_reply) do
    info_request.report!('Vexatious', 'Please check', FactoryBot.create(:user))
    message = reply_to(info_request.reload)
    routine(message)
    IncomingAttention::Classification.apply(info_request.reload)
    post attention_dismissal_path(url_title: info_request.url_title), params: {
      incoming_message_ids: [message.id]
    }
    expect(IncomingAttention::Prediction.for_message(message).
           human_reviewed_at).to be_present
    message.response_event
  end

  it 'keeps the refusal as the decision while the request is reported' do
    expect(info_request.reload.described_state).to eq('attention_requested')
    expect(decision.reload.calculated_state).to eq('rejected')
    expect(Deadlines::Stage.decision_response(info_request)).to eq(decision)
  end

  it 'keeps the refusal as the decision after an admin reverts' do
    reset!
    sign_in(admin)
    post revert_report_admin_request_path(info_request), params: {
      report_event_id: info_request.reload.last_report_event.id
    }

    expect(info_request.reload.described_state).to eq('rejected')
    expect(decision.reload.calculated_state).to eq('rejected')
    expect(Deadlines::Stage.decision_response(info_request)).to eq(decision)
    expect(Deadlines::Stage.decision?(info_request, routine_reply.reload)).
      to be(false)
    expect(Deadlines::NextAction.for(info_request.reload).kind).
      to eq(:ask_review)
  end
end
