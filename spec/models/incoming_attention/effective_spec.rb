require 'spec_helper'

RSpec.describe IncomingAttention::Effective do
  include_context 'with lean attention predictions'
  let(:user) { FactoryBot.create(:pro_user, trusted: true) }
  let(:request) { FactoryBot.create(:info_request, user: user) }

  it 'makes only a complete current bounded SKIP routine' do
    message = lean_response(request, 'SKIP')
    expect(described_class.decision(message).routine?).to eq(true)
    expect(
      IncomingAttention::Prediction.for_message(message).coverage_verified
    ).to eq(false)
    expect(described_class.routine.where(id: message.id)).to exist
    expect(described_class.needs_attention.where(id: message.id)).not_to exist
    expect(request.reload.awaiting_description).to eq(true)
  end

  it 'defers notifications for missing and waiting checks, but releases terminal failures' do
    message = lean_response(request)
    expect(described_class.notification_pending?(message)).to eq(true)
    %w[pending running stale].each do |status|
      lean_prediction(message, 'SKIP', status: status)
      expect(described_class.notification_pending?(message)).to eq(true)
    end
    %w[complete failed input_limit restricted].each do |status|
      lean_prediction(message, 'SKIP', status: status)
      expect(described_class.notification_pending?(message)).to eq(false)
    end
    allow(IncomingAttention::Config).to receive(:enabled?).and_return(false)
    expect(described_class.notification_pending?(message)).to eq(false)
  end

  it 'keeps shortened results notify-worthy even if an eligibility attribute is set' do
    message = lean_response(request, 'SKIP')
    row = IncomingAttention::Prediction.for_message(message)
    row.update!(eligible: true,
                coverage_verified: false,
                restrictions: %w[input_truncated truncation_quoted_history])
    expect(row).to be_truncated
    expect(row).not_to be_eligible
    expect(row.eligible?).to be false
    expect(described_class.needs_attention.where(id: message.id)).to exist
    expect(described_class.routine.where(id: message.id)).not_to exist
  end

  %w[pending running failed input_limit restricted stale].each do |status|
    it "keeps #{status} mail attention-worthy" do
      message = lean_response(request)
      lean_prediction(message, 'SKIP', status: status)
      expect(described_class.decision(message).needs_attention?).to eq(true)
      expect(described_class.needs_attention.where(id: message.id)).to exist
    end
  end

  it 'keeps missing, provisional and stale predictions attention-worthy' do
    missing = lean_response(request)
    provisional = lean_response(request, 'SKIP', verified: false)
    stale = lean_response(request, 'SKIP')
    IncomingAttention::Prediction.for_message(stale).update!(status: 'stale')
    [missing, provisional, stale].each do |message|
      expect(described_class.decision(message).needs_attention?).to eq(true)
      expect(described_class.routine.where(id: message.id)).not_to exist
    end
  end

  it 'does not rebuild the input for provisional decisions' do
    message = lean_response(request, 'SKIP', verified: false)
    expect(IncomingAttention::Input).not_to receive(:build)
    expect(described_class.decision(message).needs_attention?).to eq(true)
  end

  it 'uses the same strict decision for admin support and malformed native routing' do
    message = lean_response(request, 'ADMIN_SUPPORT')
    expect(described_class.decision(message).route).to eq('ADMIN_SUPPORT')
    expect(described_class.needs_attention.where(id: message.id)).to exist
    IncomingAttention::Prediction.for_message(
      message
    ).update!(eligible: false, coverage_verified: false)
    expect(described_class.decision(message).label).
      to eq('Delivery support needed')
    expect(described_class.decision(message).needs_attention?).to eq(true)
    IncomingAttention::Prediction.for_message(
      message
    ).update!(route: 'SKIP', needs_check: true)
    expect(described_class.decision(message).routine?).to eq(false)
  end

  it 'keeps an earlier unclassified response after a later routine receipt' do
    earlier = lean_response(request, 'REVIEW')
    later = lean_response(request, 'SKIP')
    expect(described_class.needs_attention.where(
      info_request_id: request.id
    ).pluck(:id)).to eq([earlier.id])
    expect(
      described_class.routine.where(info_request_id: request.id).pluck(:id)
    ).to eq([later.id])
  end

  it 'respects existing core human classification without a new review record' do
    earlier = lean_response(request, 'REVIEW')
    expect(described_class.reviewed?(earlier)).to eq(false)
    request.set_described_state('waiting_response', user)
    expect(earlier.response_event.reload.last_described_at).to be_present
    expect(described_class.reviewed?(earlier)).to eq(true)
    expect(described_class.needs_attention.where(info_request_id: request.id)).
      not_to exist
    later = lean_response(request, 'SKIP')
    expect(described_class.reviewed?(later)).to eq(false)
    expect(described_class.reviewed?(earlier)).to eq(true)
    expect(described_class.needs_attention.where(id: earlier.id)).not_to exist
    expect(described_class.routine.where(id: earlier.id)).not_to exist
    expect(described_class.needs_attention.where(info_request_id: request.id)).
      not_to exist
    expect(request.awaiting_description).to eq(true)
    expect(request.described_state).to eq('waiting_response')
  end

  it 'removes human-classified routine receipts from the live routine folder' do
    message = lean_response(request, 'SKIP')
    expect(described_class.routine.where(id: message.id)).to exist
    request.set_described_state('waiting_response', user)
    expect(described_class.routine.where(id: message.id)).not_to exist
    expect(described_class.decision(message).routine?).to eq(true)
  end

  prior_routes = %w[REVIEW SKIP REVIEW]
  { 'pending' => nil,
    'routine' => 'SKIP',
    'attention' => 'REVIEW' }.each do |kind, route|
    it "keeps older correspondence classified after a new #{kind} receipt" do
      target = request
      stamp = target.info_request_events.maximum(:created_at).change(
        usec: 0
      ) + 1.second
      travel_to(stamp) do
        older = prior_routes.map { |old_route|
          lean_response(target, old_route)
        }
        target.set_described_state('waiting_response', user)
        expect(older.first.response_event.reload.last_described_at).to be_nil
        newer = lean_response(target, route)
        expect((older + [newer]).map { |message|
          message.response_event.created_at
        }.uniq).to eq([stamp])
        lean_prediction(newer, 'SKIP', status: 'pending') unless route
        expect(older.map { |message|
          described_class.reviewed?(message.reload)
        }).to eq([true, true, true])
        expect(described_class.reviewed?(newer.reload)).to eq(false)
        expect(described_class.needs_attention.where(id: older.map(&:id))).
          not_to exist
        expect(described_class.routine.where(id: older.map(&:id))).not_to exist
        expected = kind == 'routine' ? 'routine_updates' : 'needs_attention'
        expect(described_class.decision(newer).bucket).to eq(expected)
        target.create_or_update_request_summary
        expect(described_class.counts(user)[expected]).
          to eq(kind == 'pending' ? 0 : 1)
        expect(target.reload.awaiting_description).to eq(true)
        expect(target.described_state).to eq('waiting_response')
      end
    end
  end

  it 'keeps missing or mismatched response events unresolved' do
    missing = FactoryBot.create(:incoming_message, info_request: request)
    mismatched = lean_response(request)
    mismatched.response_event.
      update_columns(info_request_id: FactoryBot.create(:info_request).id)
    request.update!(awaiting_description: false)
    [missing, mismatched].each do |message|
      expect(described_class.reviewed?(message.reload)).to eq(false)
      expect(described_class.needs_attention.where(id: message.id)).to exist
      expect(described_class.decision(message).needs_attention?).to eq(true)
    end
  end

  it 'uses stored predictions without a source reconstruction on reads' do
    message = lean_response(request, 'SKIP')
    expect_any_instance_of(ActiveStorage::Blob).not_to receive(:download)
    expect(described_class.decision(message).routine?).to eq(true)
  end

  it 'does not read predictions or change core semantics with the one flag off' do
    message = lean_response(request, 'SKIP')
    allow(IncomingAttention::Config).to receive(:enabled?).and_return(false)
    expect(IncomingAttention::Prediction).not_to receive(:for_message)
    expect(described_class.decision(message).routine?).to eq(false)
    expect(request.reload.awaiting_description?).to eq(true)
    expect(request.calculate_status).to eq('waiting_classification')
  end

  it 'excludes owner-unreadable hidden correspondence' do
    message = lean_response(request)
    message.update!(prominence: 'hidden')
    expect(Ability.new(user).can?(:read, message)).to eq(false)
    expect(described_class.needs_attention.where(id: message.id)).not_to exist
  end

  it 'counts a mixed batch once in each destination and preserves raw categories' do
    batch = FactoryBot.create(:info_request_batch, :sent, user: user,
                                                          public_body_count: 2)
    children = batch.info_requests.to_a
    lean_response(children[0], 'REVIEW')
    lean_response(children[1], 'SKIP')
    batch.create_or_update_request_summary
    categories = batch.request_summary.request_summary_categories.pluck(:id)
    expect(described_class.counts(user)).
      to eq('needs_attention' => 1, 'routine_updates' => 1)
    expect(batch.request_summary.reload.request_summary_categories.pluck(:id)).
      to eq(categories)
  end

  it 'loads dashboard predictions without parsing correspondence or reconstructing source identities' do
    Array.new(5) { lean_response(request, 'SKIP') }
    request.set_described_state('waiting_response', user)
    pending = Array.new(2) { lean_response(request, 'SKIP') }
    expect_any_instance_of(IncomingMessage).not_to receive(:parse_raw_email)
    expect_any_instance_of(ActiveStorage::Blob).not_to receive(:download)
    expect(described_class.routine(
      IncomingMessage.where(info_request_id: request.id)
    ).pluck(:id)).to match_array(pending.map(&:id))
    expect(described_class.counts(user)).
      to eq('needs_attention' => 0, 'routine_updates' => 2)
  end

  it 'does not expire stored predictions for unrelated metadata changes' do
    message = lean_response(request, 'SKIP')
    request.public_body.update!(name: 'Renamed authority')
    expect(described_class.decision(message.reload).routine?).to eq(true)
  end
  it 'keeps historical mail visible and notify-worthy without opting in to backfill' do
    message = lean_response(request)
    IncomingAttention::Prediction.for_message(message).destroy!
    allow(IncomingAttention::Config).
      to receive(:backfill_received_after).and_return(nil)
    expect(described_class.notification_pending?(message)).to be false
    expect(
      described_class.dashboard_attention(IncomingMessage.where(id: message.id))
    ).to exist
    expect(described_class.inbox(user)).to include(checking: 0)
    expect(described_class.inbox(user)[:attention].map { |reply|
      reply.message.id
    }).to include(message.id)
  end

  it 'holds only explicitly opted-in missing historical checks, using receipt time' do
    message = lean_response(request)
    IncomingAttention::Prediction.for_message(message).destroy!
    cutoff = Time.current.change(usec: 0)
    message.update_columns(created_at: cutoff - 1.second,
                           sent_at: cutoff + 1.day)
    allow(IncomingAttention::Config).
      to receive(:backfill_received_after).and_return(cutoff)
    expect(described_class.notification_pending?(message)).to be false
    expect(
      described_class.dashboard_attention(IncomingMessage.where(id: message.id))
    ).to exist
    message.update_columns(created_at: cutoff, sent_at: cutoff - 1.year)
    expect(described_class.notification_pending?(message)).to be true
    expect(
      described_class.dashboard_attention(IncomingMessage.where(id: message.id))
    ).not_to exist
    expect(described_class.inbox(user)).to include(checking: 1)
  end

  it 'excludes holding-pen backfill before querying replies' do
    message = lean_response(request)
    IncomingAttention::Prediction.for_message(message).destroy!
    allow(IncomingAttention::Config).
      to receive(:backfill_received_after).and_return(
        message.created_at - 1.minute
      )
    expect(InfoRequest).not_to receive(:holding_pen_request)
    expect(described_class.notification_pending?(message)).to be true

    request.update_column(:url_title, 'holding_pen')
    expect(described_class).not_to receive(:unresolved)
    expect(described_class.notification_pending?(message)).to be false
  end

  it 'holds a missing check after the backfill cutoff only while the reply is unresolved' do
    message = lean_response(request)
    IncomingAttention::Prediction.for_message(message).destroy!
    allow(IncomingAttention::Config).
      to receive(:backfill_received_after).and_return(
        message.created_at - 1.minute
      )
    expect(described_class.notification_pending?(message)).to be true
    request.update_columns(awaiting_description: false)
    expect(described_class.unresolved(IncomingMessage.where(id: message.id))).
      not_to exist
    expect(described_class.notification_pending?(message.reload)).to be false
  end

  it 'logs a fixed code when it cannot work a decision out' do
    message = lean_response(request, 'SKIP')
    allow(IncomingAttention::Prediction).to receive(:for_message).
      and_raise(ActiveRecord::StatementInvalid)
    allow(Rails.logger).to receive(:warn).and_call_original
    expect(described_class.decision(message).reason).to eq(:unavailable)
    expect(Rails.logger).to have_received(:warn).with(
      "incoming_attention_decision_failed message_id=#{message.id} " \
      'ActiveRecord::StatementInvalid'
    )
  end
end
