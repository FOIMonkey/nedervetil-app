RSpec.shared_context 'with lean attention predictions' do
  before do
    allow(IncomingAttention::Config).to receive(:enabled?).and_return(true)
    allow(IncomingAttention::Job).
      to receive(:perform_later).and_return(double('queued'))
  end

  def lean_prediction(message, route = 'SKIP', verified: true, status: 'complete')
    row = IncomingAttention::Prediction.ensure_for(message)
    row.update!(status: status,
                route: route,
                needs_check: route != 'SKIP',
                eligible: verified,
                coverage_verified: false,
                restrictions: [],
                config_fingerprint: 'legacy-deployment-fingerprint',
                source_signature: 'legacy-source-signature',
                input_fingerprint: '1' * 64,
                state_sha256: '2' * 64,
                source_revision_sha256: '3' * 64,
                response_event_id: message.response_event.id)
    row
  end

  def lean_response(target, route = nil, verified: true, days_ago: 0)
    message = FactoryBot.create(:incoming_message, info_request: target)
    FactoryBot.create(:response_event,
                      info_request: target,
                      incoming_message: message,
                      created_at: days_ago.days.ago)
    target.reload.update!(awaiting_description: true)
    lean_prediction(message, route, verified: verified) if route
    message
  end
end
