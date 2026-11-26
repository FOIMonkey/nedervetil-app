require 'spec_helper'
RSpec.describe IncomingAttention::Prediction do
  include_context 'with lean attention predictions'
  let(:request) { FactoryBot.create(:info_request) }
  it 'keeps completed historical predictions current, without email queries' do
    message = lean_response(request, 'SKIP')
    row = described_class.for_message(message)
    row.update!(native_response: { 'model' => 'clef-flash', 'answers' => {} })
    expect(message).not_to receive(:raw_email)
    expect(row.current?(message)).to be true
    expect(IncomingAttention::Effective.routine?(message)).to be true
    expect(IncomingAttention::Effective.dashboard_ready(
             IncomingMessage.where(id: message.id)
           )).to exist
  end
  it 'does not invalidate a stored prediction on attachment creation or authority rename' do
    message = lean_response(request, 'SKIP')
    FactoryBot.create(:pdf_attachment, incoming_message: message)
    request.public_body.update!(name: 'Renamed Council')
    expect(described_class.for_message(message).status).to eq('complete')
  end
  it 'invalidates on visibility changes and clears the stored payload' do
    message = lean_response(request, 'SKIP')
    message.update!(prominence: 'hidden')
    expect(described_class.for_message(message)).
      to have_attributes(status: 'stale', native_response: nil, eligible: false)
  end
  it 'records failed enqueue and recovers it using the database independently of Sidekiq' do
    message = lean_response(request)
    row = described_class.ensure_for(message)
    allow(IncomingAttention::Job).
      to receive(:perform_later).and_raise('Synthetic Redis outage')
    allow(Rails.logger).to receive(:warn).and_call_original
    expect(row.enqueue!).to be false
    expect(row.reload.error_code).to eq('enqueue_failed')
    expect(Rails.logger).to have_received(:warn).
      with("incoming_attention_enqueue_failed prediction_id=#{row.id} " \
           'RuntimeError')
    row.update_columns(updated_at: 6.minutes.ago)
    allow(IncomingAttention::Job).
      to receive(:perform_later).and_return(double('queued'))
    expect(IncomingAttention::Job).to receive(:perform_later).with(row.id)
    IncomingAttention::Recovery.run
    expect(row.reload.status).to eq('pending')
  end
  it 'requeues crashed work and stops retrying at a bounded attempt limit' do
    message = lean_response(request)
    row = described_class.ensure_for(message)
    row.update!(status: 'running', attempts: 1, updated_at: 6.minutes.ago)
    IncomingAttention::Recovery.run
    expect(row.reload.status).to eq('pending')
    row.update!(status: 'running', attempts: 5, updated_at: 6.minutes.ago)
    IncomingAttention::Recovery.run
    expect(row.reload).
      to have_attributes(status: 'failed', error_code: 'attempts_exhausted')
    expect(IncomingAttention::Effective.notification_pending?(message)).
      to be false
  end
  it 'puts classification on its own queue' do
    expect(IncomingAttention::Job.queue_name).to eq('incoming_attention')
  end
  it 'recovers existing checks without creating checks for mail received while disabled' do
    existing = lean_response(request)
    row = described_class.for_message(existing)
    row.update_columns(updated_at: 6.minutes.ago)
    allow(IncomingAttention::Config).to receive(:enabled?).and_return(false)
    historical = lean_response(request)
    allow(IncomingAttention::Config).to receive(:enabled?).and_return(true)
    allow(IncomingAttention::Config).
      to receive(:backfill_received_after).and_return(nil)
    expect(IncomingAttention::Job).to receive(:perform_later).with(row.id).once
    IncomingAttention::Recovery.run
    expect(described_class.for_message(historical)).to be_nil
    expect(row.reload.updated_at).to be > 1.minute.ago
  end

  it 'excludes holding-pen junk before the backfill limit and processes messages in ID order' do
    holding = FactoryBot.create(:info_request,
                                user: FactoryBot.create(:admin_user))
    holding.update_column(:url_title, 'holding_pen')
    FactoryBot.create_list(:incoming_message, 101, info_request: holding)
    allow(IncomingAttention::Config).to receive(:enabled?).and_return(false)
    older = lean_response(request)
    first = lean_response(request)
    second = lean_response(request)
    cutoff = 1.hour.ago
    older.update_columns(created_at: cutoff - 1.second, sent_at: 1.day.from_now)
    first.update_columns(created_at: cutoff, sent_at: 1.year.ago)
    allow(IncomingAttention::Config).to receive(:enabled?).and_return(true)
    allow(IncomingAttention::Config).
      to receive(:backfill_received_after).and_return(cutoff)
    IncomingAttention::Recovery.run(limit: 1)
    expect(described_class.for_message(first)).to be_present
    expect(described_class.for_message(second)).to be_nil
    expect(described_class.for_message(older)).to be_nil
    IncomingAttention::Recovery.run(limit: 1)
    expect(described_class.for_message(second)).to be_present
    expect(described_class.where(info_request_id: holding.id)).not_to exist
    expect(
      IncomingAttention::Effective.unresolved.where(info_request_id: holding.id)
    ).not_to exist
  end

  it 'does not reset a prediction completed after recovery selected it' do
    row = described_class.ensure_for(lean_response(request))
    row.update!(status: 'running', updated_at: 6.minutes.ago)
    allow_any_instance_of(described_class).
      to receive(
        :compare_and_update
      ).and_wrap_original do |original, attributes|
      if attributes[:status] == 'pending'
        row.update!(status: 'complete', route: 'SKIP', eligible: true)
      end
      original.call(attributes)
    end
    expect(IncomingAttention::Job).not_to receive(:perform_later)
    IncomingAttention::Recovery.run
    expect(row.reload).
      to have_attributes(status: 'complete', route: 'SKIP', eligible: true)
  end
  it 'does not overwrite a running or completed check when enqueue reporting fails' do
    row = described_class.ensure_for(lean_response(request))
    allow(IncomingAttention::Job).to receive(:perform_later) do
      described_class.find(row.id).compare_and_update(status: 'complete',
                                                      route: 'SKIP',
                                                      eligible: true)
      raise 'Synthetic uncertain enqueue result'
    end
    expect(row.enqueue!).to be false
    expect(row.reload).
      to have_attributes(status: 'complete', route: 'SKIP', eligible: true)
  end
  it 'retries an asynchronous masking window but bounds the retry count' do
    row = described_class.ensure_for(lean_response(request))
    row.update!(status: 'restricted',
                error_code: 'masking_pending',
                attempts: 1,
                updated_at: 6.minutes.ago)
    IncomingAttention::Recovery.run
    expect(row.reload.status).to eq('pending')
    row.update!(status: 'restricted',
                error_code: 'masking_pending',
                attempts: 5,
                updated_at: 6.minutes.ago)
    IncomingAttention::Recovery.run
    expect(row.reload).
      to have_attributes(status: 'failed', error_code: 'attempts_exhausted')
  end
  it 'invalidates stored predictions when an attachment is hidden or erased' do
    message = lean_response(request, 'SKIP')
    part = FactoryBot.create(:pdf_attachment, incoming_message: message)
    part.update!(prominence: 'hidden')
    expect(described_class.for_message(message)).
      to have_attributes(status: 'stale', native_response: nil, eligible: false)
    lean_prediction(message)
    part.update!(erased_at: Time.current)
    expect(described_class.for_message(message).status).to eq('stale')
  end
end
