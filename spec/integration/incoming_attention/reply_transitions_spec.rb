require 'spec_helper'

# Fibers pause each job at the Worker call to control result arrival order.
RSpec.describe 'Late reply outcome results' do
  include_context 'with lean attention predictions'
  let(:request) { FactoryBot.create(:info_request) }
  let!(:message) { lean_response(request, 'REVIEW') }
  let(:row) { IncomingAttention::Prediction.for_message(message) }
  let(:job) { IncomingAttention::Outcome::Job }
  let(:built) do
    IncomingAttention::Outcome::Input::Built.new(
      signals: {},
      request: { 'contract_version' => 'request-outcome/v2',
                 'message_id' => message.id.to_s,
                 'info_request_id' => request.id.to_s }
    )
  end

  before do
    allow(AlaveteliConfiguration).
      to receive(:incoming_outcome_mode).and_return('apply')
    allow(job).to receive(:perform_later)
    allow(IncomingAttention::Outcome::Input).
      to receive(:build).and_return(built)
    allow(IncomingAttention::Outcome::Input).to receive(:recheck!)
  end

  def answer(call)
    { 'inference_status' => 'complete', 'call' => call,
      'reasons' => [], 'withheld_under' => [], 'mentions' => [],
      'input_truncated' => false, 'diagnostics' => {} }
  end

  def pending_job(result)
    restart_triage if row.reload.status == 'stale'
    IncomingAttention::Outcome.queue(row.reload, message.reload)
    held_job(result)
  end

  def held_job(result)
    client = double('local outcome worker')
    allow(client).to receive(:assess) do
      Fiber.yield :waiting_for_worker
      raise result if result.is_a?(Exception)

      result
    end
    allow(job).to receive(:client_factory).and_return(-> { client })
    Fiber.new { job.new.perform(row.id) }.tap do |fiber|
      expect(fiber.resume).to eq(:waiting_for_worker)
      expect(row.reload.outcome_status).to eq('running')
    end
  end

  def restart_triage
    input = bounded_input
    snapshot = IncomingAttention::Input::Snapshot.new(
      request: input, restrictions: [], info_request_id: request.id,
      response_event_id: message.response_event.id
    )
    allow(IncomingAttention::Input).to receive(:build).and_return(snapshot)
    allow(IncomingAttention::Input).to receive(:available?).and_return(true)
    triage = double('local restarted triage',
                    classify: bounded_worker_response(input, route: 'REVIEW'))
    allow(IncomingAttention::Job).
      to receive(:client_factory).and_return(-> { triage })
    IncomingAttention::Job.new.perform(row.id)
    expect(row.reload).
      to have_attributes(status: 'complete', outcome_status: 'pending')
  end

  it 'preserves a human outcome made while a successful inference is ' \
     'outstanding, including duplicate delivery' do
    delayed = pending_job(answer('all'))
    request.reload.set_described_state('rejected', request.user)
    delayed.resume
    2.times { job.new.perform(row.id) }
    expect(request.reload.described_state).to eq('rejected')
    expect(row.reload.human_reviewed_at).to be_present
    expect(row.outcome_applied_state).to be_nil
  end

  it 'does not apply an old outcome after invalidation without restart' do
    delayed = pending_job(answer('all'))
    row.reload.invalidate!(reason: 'visibility_changed')
    delayed.resume
    expect(row.reload.outcome_status).to be_nil
    expect(row.outcome_call).to be_nil
    expect(request.reload.awaiting_description?).to be(true)
  end

  it 'keeps a newer completed outcome when the old success arrives last' do
    old = pending_job(answer('all'))
    row.reload.invalidate!(reason: 'visibility_changed')
    recent = pending_job(answer('refused'))
    recent.resume
    old.resume
    expect(row.reload.outcome_call).to eq('refused')
    expect(request.reload.described_state).to eq('rejected')
  end

  [[:success, nil], [:failure, 'provider_timeout']].each do |kind, error|
    it "rejects an old #{kind} while the replacement outcome job is " \
       'still running' do
      result =
        error ? IncomingAttention::Client::Error.new(error) : answer('all')
      old = pending_job(result)
      row.reload.invalidate!(reason: 'visibility_changed')
      recent = pending_job(answer('refused'))
      old.resume
      state_after_old = row.reload.outcome_status
      call_after_old = row.outcome_call
      awaiting_after_old = request.reload.awaiting_description?
      recent.resume
      aggregate_failures 'only the newer attempt may finish its claim' do
        expect(state_after_old).to eq('running')
        expect(call_after_old).to be_nil
        expect(awaiting_after_old).to be(true)
        expect(row.reload.outcome_status).to eq('complete')
        expect(row.outcome_call).to eq('refused')
        expect(request.reload.described_state).to eq('rejected')
      end
    end
  end

  it 'rejects an old success even when the clock has not moved' do
    freeze_time do
      old = pending_job(answer('all'))
      row.reload.invalidate!(reason: 'visibility_changed')
      recent = pending_job(answer('refused'))
      old.resume
      expect(row.reload).
        to have_attributes(outcome_status: 'running', outcome_call: nil)
      recent.resume
      expect(row.reload.outcome_call).to eq('refused')
    end
  end
end

RSpec.describe 'Late reply outcome results after recovery' do
  include_context 'with lean attention predictions'
  let(:request) { FactoryBot.create(:info_request) }
  let!(:message) { lean_response(request, 'REVIEW') }
  let(:row) { IncomingAttention::Prediction.for_message(message) }
  let(:job) { IncomingAttention::Outcome::Job }
  let(:built) do
    IncomingAttention::Outcome::Input::Built.new(
      signals: {},
      request: { 'contract_version' => 'request-outcome/v2',
                 'message_id' => message.id.to_s,
                 'info_request_id' => request.id.to_s }
    )
  end

  before do
    allow(AlaveteliConfiguration).
      to receive(:incoming_outcome_mode).and_return('apply')
    allow(job).to receive(:perform_later)
    allow(IncomingAttention::Outcome::Input).
      to receive(:build).and_return(built)
    allow(IncomingAttention::Outcome::Input).to receive(:recheck!)
  end

  def held_job(call)
    client = double('local outcome worker')
    allow(client).to receive(:assess) do
      Fiber.yield :waiting_for_worker
      { 'inference_status' => 'complete', 'call' => call,
        'reasons' => [], 'withheld_under' => [], 'mentions' => [],
        'input_truncated' => false, 'diagnostics' => {} }
    end
    allow(job).to receive(:client_factory).and_return(-> { client })
    Fiber.new { job.new.perform(row.id) }.tap do |fiber|
      expect(fiber.resume).to eq(:waiting_for_worker)
    end
  end

  it 'rejects a late result from a job that recovery has replaced' do
    IncomingAttention::Outcome.queue(row, message)
    old = held_job('all')
    travel 11.minutes
    IncomingAttention::Recovery.outcomes(10)
    expect(row.reload.outcome_status).to eq('pending')
    recent = held_job('refused')
    old.resume
    expect(row.reload).
      to have_attributes(outcome_status: 'running', outcome_call: nil)
    recent.resume
    expect(row.reload.outcome_call).to eq('refused')
    expect(request.reload.described_state).to eq('rejected')
  end
end

RSpec.describe 'Late reply triage results' do
  include_context 'with lean attention predictions'
  let(:request) { FactoryBot.create(:info_request) }
  let!(:message) { lean_response(request) }
  let(:row) { IncomingAttention::Prediction.for_message(message) }
  let(:input) { bounded_input }

  before do
    snapshot = IncomingAttention::Input::Snapshot.new(
      request: input, restrictions: [], info_request_id: request.id,
      response_event_id: message.response_event.id
    )
    allow(IncomingAttention::Input).to receive(:build).and_return(snapshot)
    allow(IncomingAttention::Input).to receive(:available?).and_return(true)
  end

  def delayed_triage(route)
    client = double('local triage worker')
    allow(client).to receive(:classify) do
      Fiber.yield :waiting_for_worker
      bounded_worker_response(input, route: route)
    end
    allow(IncomingAttention::Job).
      to receive(:client_factory).and_return(-> { client })
    Fiber.new { IncomingAttention::Job.new.perform(row.id) }.tap do |fiber|
      expect(fiber.resume).to eq(:waiting_for_worker)
    end
  end

  it 'keeps a human status while late routine triage and duplicate jobs ' \
     'complete' do
    old = delayed_triage('SKIP')
    request.reload.set_described_state('rejected', request.user)
    old.resume
    IncomingAttention::Job.new.perform(row.id)
    expect(request.reload.described_state).to eq('rejected')
    expect(row.reload.human_reviewed_at).to be_present
  end

  [true, false].each do |old_first|
    it 'keeps restarted triage authoritative when old result finishes ' \
       "#{old_first ? 'first' : 'last'}" do
      old = delayed_triage('SKIP')
      row.reload.invalidate!(reason: 'visibility_changed')
      recent = delayed_triage('REVIEW')
      if old_first
        old.resume
        expect(row.reload.status).to eq('running')
        recent.resume
      else
        recent.resume
        old.resume
      end
      expect(row.reload).to have_attributes(status: 'complete', route: 'REVIEW')
      expect(request.reload.awaiting_description?).to be(true)
    end
  end
end
