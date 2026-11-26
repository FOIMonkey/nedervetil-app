require 'spec_helper'
RSpec.describe IncomingAttention::Job do
  include_context 'with lean attention predictions'
  let(:request) { FactoryBot.create(:info_request) }
  let(:message) { lean_response(request) }
  let(:row) { IncomingAttention::Prediction.for_message(message) }
  let(:snapshot) { IncomingAttention::Input::Snapshot.new(request: bounded_input, restrictions: [], info_request_id: request.id, response_event_id: message.response_event.id) }
  let(:response) {
    bounded_worker_response(snapshot.request,
                            labels: { 'routine' => 'ACKNOWLEDGEMENT',
                                      'attention' => nil })
  }
  before do
    allow(IncomingAttention::Input).
      to receive(:build).with(message).and_return(snapshot)
    allow(IncomingAttention::Input).to receive(:available?).and_return(true)
  end
  it 'prepares once, stores the result and makes repeat jobs harmless' do
    client = double('client')
    expect(client).to receive(:classify).once.and_return(response)
    allow(described_class).to receive(:client_factory).and_return(-> { client })
    expect(IncomingAttention::Input).
      to receive(:build).once.and_return(snapshot)
    described_class.new.perform(row.id)
    expect(row.reload).
      to have_attributes(status: 'complete', restrictions: [], reply_labels: {
                           'routine' => 'ACKNOWLEDGEMENT',
                           'attention' => nil
                         }, native_response: response['diagnostics'])
    described_class.new.perform(row.id)
  end
  it 'records the Worker shortening a reply as a restriction' do
    client = double('client',
                    classify: response.merge('input_truncated' => true,
                                             'eligibility' => false))
    allow(described_class).to receive(:client_factory).and_return(-> { client })
    described_class.new.perform(row.id)
    expect(row.reload).
      to have_attributes(status: 'complete',
                         eligible: false,
                         restrictions: ['input_truncated'])
    expect(IncomingAttention::Effective.routine?(message)).to be false
  end
  it 'keeps a human attention choice made during inference' do
    client = double('client')
    allow(client).
      to receive(:classify) {
        row.update_columns(attention_override: 'attention')
        response
      }
    allow(described_class).to receive(:client_factory).and_return(-> { client })
    described_class.new.perform(row.id)
    expect(row.reload.attention_override).to eq('attention')
    expect(request.reload.awaiting_description?).to be true
    expect(IncomingAttention::Effective.decision(message).needs_attention?).
      to be true
  end
  it 'does not accept a result after erasure or visibility invalidation' do
    client = double('client')
    allow(client).to receive(:classify) {
      row.invalidate!(reason: 'raw_erased')
      response
    }
    allow(described_class).to receive(:client_factory).and_return(-> { client })
    described_class.new.perform(row.id)
    expect(row.reload.status).to eq('stale')
    expect(row.native_response).to be_nil
  end
  it 'keeps a failed attempt visible and notify-worthy with a fixed error' do
    client = double('client')
    allow(client).to receive(:classify).and_raise(IncomingAttention::Client::Error.new('transport_failure'))
    allow(described_class).to receive(:client_factory).and_return(-> { client })
    described_class.new.perform(row.id)
    expect(row.reload).
      to have_attributes(status: 'failed', error_code: 'transport_failure')
    expect(IncomingAttention::Effective.notification_pending?(message)).
      to be false
  end
  it 'logs the class of an unexpected error, and never its message' do
    client = instance_double(IncomingAttention::Client)
    allow(client).to receive(:classify).
      and_raise(ArgumentError, 'Dear requester, the text of a reply')
    allow(described_class).to receive(:client_factory).and_return(-> { client })
    allow(Rails.logger).to receive(:warn).and_call_original
    described_class.new.perform(row.id)
    expect(row.reload).
      to have_attributes(status: 'failed', error_code: 'unexpected_failure')
    expect(Rails.logger).to have_received(:warn).with(
      "incoming_attention_unexpected_failure prediction_id=#{row.id} " \
      'ArgumentError'
    )
    expect(Rails.logger).
      not_to have_received(:warn).with(/the text of a reply/)
  end
  it 'can retry a failed core classification without another model call' do
    client = double('client')
    expect(client).to receive(:classify).once.and_return(response)
    allow(described_class).to receive(:client_factory).and_return(-> { client })
    allow(IncomingAttention::Classification).
      to receive(:apply).and_raise('Synthetic DB failure')
    expect { described_class.new.perform(row.id) }.
      to raise_error(RuntimeError, 'incoming_attention_classification_failed')
    expect(row.reload.status).to eq('complete')
    allow(IncomingAttention::Classification).
      to receive(:apply).and_call_original
    described_class.new.perform(row.id)
    expect(request.reload.awaiting_description?).to be false
  end

  it 'does not overwrite an invalidation between its availability check and SQL write' do
    client = double('client', classify: response)
    allow(described_class).to receive(:client_factory).and_return(-> { client })
    allow_any_instance_of(IncomingAttention::Prediction).
      to receive(
        :compare_and_update
      ).and_wrap_original do |original, attributes|
      if attributes[:status] == 'complete'
        row.invalidate!(reason: 'visibility_changed')
      end
      original.call(attributes)
    end
    described_class.new.perform(row.id)
    expect(row.reload).
      to have_attributes(status: 'stale', native_response: nil, route: nil)
  end
  it 'does not accept an older result after invalidation and a new running check' do
    client = double('client')
    allow(client).to receive(:classify) do
      row.invalidate!(reason: 'visibility_changed')
      row.compare_and_update(status: 'running', attempts: 1)
      response
    end
    allow(described_class).to receive(:client_factory).and_return(-> { client })
    freeze_time { described_class.new.perform(row.id) }
    expect(row.reload).
      to have_attributes(status: 'running', native_response: nil, route: nil)
  end
  it 'does not let an older failed check overwrite a restarted check' do
    client = double('client')
    allow(client).to receive(:classify) do
      row.invalidate!(reason: 'visibility_changed')
      row.compare_and_update(status: 'running', attempts: 1)
      raise IncomingAttention::Client::Error, 'transport_failure'
    end
    allow(described_class).to receive(:client_factory).and_return(-> { client })
    described_class.new.perform(row.id)
    expect(row.reload.status).to eq('running')
    expect(row.error_code).to eq('visibility_changed')
  end
  it 'does not run an overlapping duplicate job' do
    row.update!(status: 'running')
    expect(IncomingAttention::Input).not_to receive(:build)
    described_class.new.perform(row.id)
    expect(row.reload.status).to eq('running')
  end

  it 'defers without consuming attempts using the waiting blob age, even on ' \
     'an older prediction, and caps waiting after 24 hours' do
    docx_type =
      'application/vnd.openxmlformats-officedocument.' \
      'wordprocessingml.document'
    part = FactoryBot.create(:foi_attachment, incoming_message: message,
                                              filename: 'reply.docx',
                                              content_type: docx_type)
    part.file.attach(
      io: StringIO.new(OfficeFixtures.word('<w:p/>')),
      filename: 'reply.docx', content_type: docx_type
    )
    row.update_columns(created_at: 3.days.ago)
    allow(IncomingAttention::Input).to receive(:build).
      and_raise(IncomingAttention::Input::Unavailable, 'analysis_pending')
    allow(IncomingAttention::Input).to receive(:available?).and_call_original
    delayed = double('delayed')
    allow(described_class).to receive(:set).with(wait: 15.seconds).
      and_return(delayed)
    expect(delayed).to receive(:perform_later).with(row.id)

    described_class.new.perform(row.id)
    expect(row.reload).
      to have_attributes(status: 'pending', attempts: 0,
                         error_code: 'analysis_pending')

    part.file_blob.update_columns(created_at: 25.hours.ago)
    described_class.new.perform(row.id)
    expect(row.reload).
      to have_attributes(status: 'restricted', error_code: 'source_unavailable')
  end

  it 'rotates still-waiting analysis_pending rows and does not starve them ' \
     'behind newer work once analysis finishes' do
    docx_type =
      'application/vnd.openxmlformats-officedocument.' \
      'wordprocessingml.document'
    part = FactoryBot.create(:foi_attachment, incoming_message: message,
                                              filename: 'wait.docx',
                                              content_type: docx_type)
    part.file.attach(
      io: StringIO.new(OfficeFixtures.word('<w:p/>')),
      filename: 'wait.docx', content_type: docx_type
    )
    old_stamp = 20.minutes.ago
    row.update_columns(status: 'restricted', error_code: 'analysis_pending',
                       updated_at: old_stamp)

    other_request = FactoryBot.create(:info_request)
    other_message = lean_response(other_request)
    other_row = IncomingAttention::Prediction.for_message(other_message)
    other_row.update_columns(status: 'pending', updated_at: 10.minutes.ago)
    allow(IncomingAttention::Input).to receive(:available?).and_call_original

    # Pass 1 rotates the still-waiting row so Pass 2 recovers other_row.
    IncomingAttention::Recovery.run(limit: 1)
    expect(row.reload.updated_at).to be > old_stamp
    expect(row.error_code).to eq('analysis_pending')

    expect(described_class).to receive(:perform_later).with(other_row.id).
      and_return(true)
    IncomingAttention::Recovery.run(limit: 1)

    # Once analysis finishes, an older analysis_pending row runs ahead of newer
    # pending work instead of being displaced to the back of every batch.
    part.file.analyze
    row.update_columns(status: 'restricted', error_code: 'analysis_pending',
                       updated_at: 20.minutes.ago)
    other_row.update_columns(status: 'pending', updated_at: 10.minutes.ago)
    expect(described_class).to receive(:perform_later).with(row.id).
      and_return(true)
    IncomingAttention::Recovery.run(limit: 1)

    # Outcome recovery follows the same FIFO ordering once analysis finishes.
    allow(AlaveteliConfiguration).
      to receive(:incoming_outcome_mode).and_return('apply')
    row.update_columns(
      outcome_status: 'pending',
      outcome_signals: { 'error' => 'analysis_pending' },
      outcome_checked_at: 20.minutes.ago
    )
    other_row.update_columns(
      outcome_status: 'pending',
      outcome_signals: {},
      outcome_checked_at: 15.minutes.ago
    )
    expect(IncomingAttention::Outcome::Job).to receive(:perform_later).
      with(row.id)
    IncomingAttention::Recovery.outcomes(1)
  end
end
