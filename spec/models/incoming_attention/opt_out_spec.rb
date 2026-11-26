require 'spec_helper'

RSpec.describe IncomingAttention::OptOut do
  describe 'checks for an account that opted out' do
    include_context 'with lean attention predictions'
    let(:owner) { FactoryBot.create(:user) }
    let(:request) { FactoryBot.create(:info_request, user: owner) }
    let(:message) { lean_response(request) }
    let(:row) { IncomingAttention::Prediction.for_message(message) }
    let(:snapshot) { IncomingAttention::Input::Snapshot.new(request: bounded_input, restrictions: [], info_request_id: request.id, response_event_id: message.response_event.id) }
    let(:client) { double('client') }

    before do
      allow(IncomingAttention::Input).to receive(:build).and_return(snapshot)
      allow(IncomingAttention::Input).to receive(:available?).and_return(true)
      allow(IncomingAttention::Job).
        to receive(:client_factory).and_return(-> { client })
    end

    it 'sends nothing, files the reply as needing attention and holds no notification' do
      described_class.set!(owner, true)
      expect(client).not_to receive(:classify)
      expect(IncomingAttention::Input).not_to receive(:build)
      expect(IncomingAttention::Outcome).not_to receive(:queue)
      IncomingAttention::Job.new.perform(row.id)
      expect(row.reload).
        to have_attributes(status: 'restricted',
                           error_code: 'opted_out',
                           route: nil,
                           reply_labels: nil)
      expect(IncomingAttention::Effective.decision(message).needs_attention?).
        to be true
      expect(IncomingAttention::Effective.notification_pending?(message)).
        to be false
    end

    it 'does not hold notifications for a reply still waiting when its owner opted out' do
      expect(IncomingAttention::Effective.notification_pending?(message)).
        to be true
      described_class.set!(owner, true)
      expect(IncomingAttention::Effective.notification_pending?(message)).
        to be false
    end

    it 'checks again just before sending' do
      allow(IncomingAttention::Input).
        to receive(:build) {
          described_class.set!(owner, true)
          snapshot
        }
      expect(client).not_to receive(:classify)
      IncomingAttention::Job.new.perform(row.id)
      expect(row.reload).
        to have_attributes(status: 'restricted', error_code: 'opted_out')
    end

    it 'lets a reading already on its way finish, though its owner opted out meanwhile' do
      allow(client).to receive(:classify) do
        described_class.set!(owner, true)
        bounded_worker_response(
          snapshot.request,
          labels: { 'routine' => 'ACKNOWLEDGEMENT', 'attention' => nil }
        )
      end
      IncomingAttention::Job.new.perform(row.id)
      expect(row.reload).
        to have_attributes(
          status: 'complete',
          reply_labels: { 'routine' => 'ACKNOWLEDGEMENT', 'attention' => nil }
        )
    end

    it 'follows the request to its current owner' do
      other = FactoryBot.create(:user)
      described_class.set!(other, true)
      request.update_columns(user_id: other.id)
      expect(client).not_to receive(:classify)
      IncomingAttention::Job.new.perform(row.id)
      expect(row.reload.error_code).to eq('opted_out')
    end

    it 'reads new replies again after opting back in, and leaves earlier readings as they were' do
      allow(client).
        to receive(:classify).and_return(bounded_worker_response(
                                           snapshot.request,
          labels: { 'routine' => 'ACKNOWLEDGEMENT', 'attention' => nil }
                                         ))
      IncomingAttention::Job.new.perform(row.id)
      described_class.set!(owner, true)
      expect(row.reload).
        to have_attributes(
          status: 'complete',
          reply_labels: { 'routine' => 'ACKNOWLEDGEMENT', 'attention' => nil }
        )
      described_class.set!(owner, false)
      later = lean_response(request)
      allow(IncomingAttention::Input).to receive(:build).and_return(snapshot)
      IncomingAttention::Job.new.perform(IncomingAttention::Prediction.for_message(later).id)
      expect(client).to have_received(:classify).twice
    end

    it 'never runs an outcome check, even when the requester marks the reply as needing attention' do
      lean_prediction(message, 'REVIEW')
      described_class.set!(owner, true)
      allow(AlaveteliConfiguration).
        to receive(:incoming_outcome_mode).and_return('apply')
      expect(IncomingAttention::Outcome::Job).not_to receive(:perform_later)
      IncomingAttention::Outcome.queue(row.reload, message)
      expect(row.reload.outcome_status).to be_nil
      row.update_columns(outcome_status: 'pending')
      expect(IncomingAttention::Outcome::Input).not_to receive(:build)
      IncomingAttention::Outcome::Job.new.perform(row.id)
      expect(row.reload).
        to have_attributes(outcome_status: 'restricted',
                           outcome_signals: { 'error' => 'opted_out' })
    end

    it 'is removed with the account' do
      described_class.set!(owner, true)
      expect { owner.destroy! }.to change(described_class, :count).by(-1)
    end
  end
end
