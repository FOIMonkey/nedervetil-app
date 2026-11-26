require 'spec_helper'
RSpec.describe IncomingAttention::Classification do
  include_context 'with lean attention predictions'
  let(:request) { FactoryBot.create(:info_request) }
  it 'uses core waiting-response status and deadlines while retaining routine dashboard correspondence' do
    dates = [request.date_response_required_by, request.date_very_overdue_after]
    message = lean_response(request, 'SKIP')
    described_class.apply(request.reload)
    expect(request.reload.awaiting_description?).to be false
    expect(request.described_state).to eq('waiting_response')
    expect([request.date_response_required_by,
            request.date_very_overdue_after]).
      to eq(dates)
    expect(IncomingAttention::Effective.unresolved(
             IncomingMessage.where(id: message.id)
           )).to exist
    expect(IncomingAttention::Effective.reviewed?(message.reload)).to be false
    expect(InfoRequest.where(id: request.id).awaiting_response).to exist
  end
  it 'does not classify away an earlier substantive answer, even if a later acknowledgement completes first' do
    answer = lean_response(request, 'REVIEW')
    lean_response(request, 'SKIP')
    described_class.apply(request.reload)
    expect(request.reload.awaiting_description?).to be true
    expect(IncomingAttention::Effective.needs_attention(
             IncomingMessage.where(id: answer.id)
           )).to exist
  end
  it 'waits for every outstanding check' do
    lean_response(request)
    lean_response(request, 'SKIP')
    described_class.apply(request.reload)
    expect(request.reload.awaiting_description?).to be true
  end
  it 'preserves human outcomes and marks earlier predictions reviewed using the existing core method' do
    message = lean_response(request, 'SKIP')
    request.log_event('status_update', described_state: 'successful')
    request.set_described_state('successful')
    described_class.apply(request.reload)
    expect(request.reload.described_state).to eq('successful')
    expect(
      IncomingAttention::Prediction.for_message(message).human_reviewed_at
    ).to be_present
    expect(IncomingAttention::Effective.unresolved(
             IncomingMessage.where(id: message.id)
           )).not_to exist
  end
  it 'lets the ordinary overdue path act on an automatically accepted acknowledgement' do
    lean_response(request, 'SKIP')
    described_class.apply(request.reload)
    request.update!(date_response_required_by: 2.days.ago.to_date,
                    date_very_overdue_after: 10.days.from_now.to_date)
    expect(request.calculate_status).to eq('waiting_response_overdue')
    expect(InfoRequest.where(id: request.id).overdue).to exist
  end
  it 'accepts a later routine acknowledgement without nagging or changing a completed human outcome' do
    lean_response(request, 'REVIEW')
    request.log_event('status_update', described_state: 'successful')
    request.set_described_state('successful')
    message = lean_response(request, 'SKIP')
    described_class.apply(request.reload)
    expect(request.reload).
      to have_attributes(described_state: 'successful',
                         awaiting_description: false)
    expect(IncomingAttention::Effective.routine(
             IncomingMessage.where(id: message.id)
           )).to exist
  end
end
