require 'spec_helper'

RSpec.describe IncomingAttention::Digest do
  include_context 'with attention digest rows'

  def cost(cached:)
    tally = Hash.new(0)
    allow(Ability).
      to receive(:new).and_wrap_original do |original, *args, **kwargs|
      tally[:abilities] += 1
      original.call(*args, **kwargs)
    end
    count = ->(*, payload) do
      sql = payload[:sql].to_s
      if payload[:cached] || payload[:name] == 'SCHEMA' || sql.match?(
        /\A\s*(BEGIN|COMMIT|ROLLBACK|SAVEPOINT|RELEASE)/i
      )
        next
      end

      tally[:statements] += 1
      if sql.include?('FROM "incoming_attention_predictions"')
        tally[:predictions] += 1
      end
      # Counts Effective.reviewed? classification checks.
      if sql.include?('"info_request_events"."described_state" IS NOT NULL')
        tally[:classified] += 1
      end
      tally[:public_bodies] += 1 if sql.include?('FROM "public_bodies"')
    end
    ActiveSupport::Notifications.subscribed(count, 'sql.active_record') do
      Rails.application.executor.wrap { cached ? send_daily : ActiveRecord::Base.uncached { send_daily } }
    end
    tally
  end

  def during_render
    allow(NotificationMailer).
      to receive(
        :daily_summary
      ).and_wrap_original do |original, *args, **kwargs|
      delivery = original.call(*args, **kwargs)
      delivery.message
      yield
      delivery
    end
  end

  it 'sends mixed sections once and consumes only successfully delivered snapshot IDs' do
    _, _, attention, = response('REVIEW')
    _, _, routine, = response('SKIP')
    expect(send_daily).to eq(true)
    expect(ActionMailer::Base.deliveries.length).to eq(1)
    expect(body).to include('Needs you', 'Also')
    expect([attention.reload.seen_at, routine.reload.seen_at]).
      to all(be_present)
    expect(send_daily).to eq(false)
  end

  it 'sends shortened SKIP as attention and never holds its ordinary notification' do
    _, _, notice, row = response('SKIP')
    row.update!(coverage_verified: false,
                eligible: true,
                restrictions: %w[input_truncated truncation_tail])
    expect(send_daily).to eq(true)
    expect(body).to include('Needs you')
    expect(notice.reload.seen_at).to be_present
  end

  it 'holds routine-only mail unseen across repeated runs without a ledger or classification writes' do
    target, _, notice, = response('SKIP')
    state = target.described_state
    3.times { expect(send_daily).to eq(false) }
    expect(ActionMailer::Base.deliveries).to be_empty
    expect(notice.reload.seen_at).to be_nil
    expect(target.reload.described_state).to eq(state)
    expect(ActiveRecord::Base.connection.tables.grep(/incoming_attention_/)).
      to match_array(%w[incoming_attention_predictions
                        incoming_attention_opt_outs
                        incoming_attention_instant_emails])
  end

  it 'sends classified REVIEW importance with its explicit reviewed label and preserves human state' do
    target, message, reviewed, = response('REVIEW')
    message.response_event.update_columns(last_described_at: Time.current)
    state = target.described_state
    expect(send_daily).to eq(true)
    expect(body).to include('Also', '· Replied')
    expect(reviewed.reload.seen_at).to be_present
    expect(target.reload.described_state).to eq(state)
  end

  it 'holds only current eligible SKIP even after existing human classification' do
    target, _, notice, = response('SKIP')
    target.update_columns(awaiting_description: false)
    expect(send_daily).to eq(false)
    expect(notice.reload.seen_at).to be_nil
  end

  it 'refuses mail inside an inherited open transaction and leaves notifications unseen' do
    _, _, notice, = response('REVIEW')
    ApplicationRecord.transaction { expect(send_daily).to eq(false) }
    expect(ActionMailer::Base.deliveries).to be_empty
    expect(notice.reload.seen_at).to be_nil
  end

  it 'includes held routine mail in a later mixed summary at the account’s next summary time' do
    _, _, routine, = response('SKIP')
    expect(send_daily).to eq(false)
    expect(IncomingAttention::Prediction.for_message(
      routine.info_request_event.incoming_message
    ).coverage_verified).to eq(false)
    summary_time = routine.reload.send_after
    expect(summary_time).to be_within(1.second).of(user.next_daily_summary_time)
    _, _, attention, = response('REVIEW', due: summary_time)
    expect(send_daily).to eq(false)
    travel_to(summary_time + 1.second) { expect(send_daily).to eq(true) }
    expect([routine.reload.seen_at, attention.reload.seen_at]).
      to all(be_present)
  end

  it 'sends held routine mail through core’s sender at its next summary time after disable' do
    _, _, notice, = response('SKIP')
    expect(send_daily).to eq(false)
    allow(IncomingAttention::Config).to receive(:enabled?).and_return(false)
    travel_to(notice.reload.send_after + 1.second) {
      expect(send_daily).to eq(true)
    }
    expect(notice.reload.seen_at).to be_present
  end

  it 'looks at a held daily account again only at its next summary time, and leaves instant rows due' do
    _, _, daily, = response('SKIP')
    _, _, instant, = response('SKIP', frequency: :instantly)
    expect(send_daily).to eq(false)
    expect(NotificationMailer.send_instant_notifications).to eq(false)
    expect(daily.reload.send_after).to be > Time.current
    expect(instant.reload.send_after).to be <= Time.current

    allow(described_class).to receive(:send_account).and_call_original
    expect(send_daily).to eq(false)
    expect(described_class).not_to have_received(:send_account)
    expect([daily.reload.seen_at, instant.reload.seen_at]).to all(be_nil)
  end

  it 'leaves closed and banned accounts out of the run, as core’s User#active? does' do
    closed = FactoryBot.create(:user)
    banned = FactoryBot.create(:user)
    spaces = FactoryBot.create(:user)
    rows = [closed, banned, spaces].to_h { |owner|
      [owner, response('REVIEW', owner: owner)[2]]
    }
    closed.update_columns(closed_at: Time.current)
    banned.update_columns(ban_text: 'Synthetic ban')
    spaces.update_columns(ban_text: " \t\u00a0\u3000")
    expect(spaces.reload).to be_active

    allow(described_class).to receive(:send_account).and_call_original
    send_daily
    expect(described_class).
      not_to have_received(:send_account).with(closed.id, any_args)
    expect(described_class).
      not_to have_received(:send_account).with(banned.id, any_args)
    expect(described_class).
      to have_received(:send_account).with(spaces.id, any_args)
    expect([rows[closed], rows[banned]].map { |row| row.reload.seen_at }).
      to all(be_nil)
    expect(rows[spaces].reload.seen_at).to be_present
  end

  it 'renders nothing for an account the mail provider would refuse, and leaves its rows unseen' do
    _, _, notice, = response('REVIEW')
    allow(described_class).to receive(:deliverable?).and_return(false)
    allow(NotificationMailer).to receive(:daily_summary).and_call_original
    allow(Rails.logger).to receive(:warn).and_call_original
    expect(Rails.logger).
      to receive(:warn).with(
        'incoming_attention_notification_recipient_not_allowed'
      ).twice
    2.times { expect(send_daily).to eq(false) }
    expect(NotificationMailer).not_to have_received(:daily_summary)
    expect(notice.reload.seen_at).to be_nil
  end

  it 'delivers to every account unless a site says otherwise' do
    expect(described_class.deliverable?(user)).to be(true)
  end

  %w[failed input_limit restricted].each do |status|
    it "sends uncertain #{status} predictions" do
      _, _, notice, prediction = response('SKIP')
      prediction.update!(status: status)
      expect(send_daily).to eq(true)
      expect(notice.reload.seen_at).to be_present
    end
  end

  it 'holds missing predictions while sending completed provisional SKIP as attention' do
    _, _, missing, = response
    _, _, provisional, = response('SKIP', verified: false)
    expect(send_daily).to eq(true)
    expect(body).to include('Needs you')
    expect(missing.reload.seen_at).to be_nil
    expect(provisional.reload.seen_at).to be_present
  end

  %w[pending running stale].each do |status|
    it "holds #{status} replies out of mixed digests without consuming them" do
      _, _, waiting, row = response('SKIP')
      row.update!(status: status)
      _, _, ready, = response('REVIEW')
      expect(send_daily).to eq(true)
      expect(waiting.reload.seen_at).to be_nil
      expect(ready.reload.seen_at).to be_present
      expect(body).not_to include(waiting.info_request_event.info_request.title)
    end

    it "does not send #{status}-only notifications until the check completes" do
      _, _, waiting, row = response('SKIP')
      row.update!(status: status)
      expect(send_daily).to eq(false)
      expect(waiting.reload.seen_at).to be_nil
      row.update!(status: 'complete', route: 'REVIEW', needs_check: true)
      expect(send_daily).to eq(true)
      expect(waiting.reload.seen_at).to be_present
    end
  end

  it 'holds a legacy direct response in the ordinary notification queue until checked' do
    target, message, notice, row = response('REVIEW')
    row.update!(status: 'pending')
    RequestMailer.new_response(target, message).deliver_now
    expect(ActionMailer::Base.deliveries).to be_empty
    expect(Notification.where(
      user: user,
      info_request_event: message.response_event
    ).count).to eq(1)
    expect(send_daily).to eq(false)
    row.update!(status: 'complete')
    expect(send_daily).to eq(true)
    expect(notice.reload.seen_at).to be_present
  end

  it 'holds pending instant notifications until checked' do
    _, _, notice, row = response('REVIEW', frequency: :instantly)
    row.update!(status: 'pending')
    expect(NotificationMailer.send_instant_notifications).to eq(false)
    expect(notice.reload.seen_at).to be_nil
    row.update!(status: 'complete')
    expect(NotificationMailer.send_instant_notifications).to eq(true)
    expect(notice.reload.seen_at).to be_present
  end

  it 'sends a failed recheck at the next summary time after holding an earlier routine-only digest' do
    _, _, notice, prediction = response('SKIP')
    expect(send_daily).to eq(false)
    prediction.update!(status: 'failed',
                       eligible: false,
                       error_code: 'provider_failure')
    travel_to(notice.reload.send_after + 1.second) {
      expect(send_daily).to eq(true)
    }
    expect(notice.reload.seen_at).to be_present
  end

  it 'uses due-ID snapshot and preserves future rows for the next account schedule' do
    _, _, due, = response('REVIEW')
    _, _, future, = response('SKIP', due: 1.day.from_now)
    late = nil
    during_render { _, _, late, = response('REVIEW') }
    expect(send_daily).to eq(true)
    expect(due.reload.seen_at).to be_present
    expect(future.reload.seen_at).to be_nil
    expect(late.reload.seen_at).to be_nil
  end

  it 'sends every account instead of short circuiting after the first successful one' do
    _, _, first, = response('REVIEW')
    _, _, second, = response('REVIEW', owner: FactoryBot.create(:user))
    expect(send_daily).to eq(true)
    expect(ActionMailer::Base.deliveries.length).to eq(2)
    expect([first.reload.seen_at, second.reload.seen_at]).to all(be_present)
  end

  it 'uses the instant schedule with the same routine hold and mixed summary' do
    _, _, routine, = response('SKIP', frequency: :instantly)
    expect(NotificationMailer.send_instant_notifications).to eq(false)
    _, _, attention, = response('REVIEW', frequency: :instantly)
    _, _, future, = response('REVIEW', frequency: :instantly,
                                       due: 1.day.from_now)
    expect(NotificationMailer.send_instant_notifications).to eq(true)
    expect(ActionMailer::Base.deliveries.last.subject).not_to include('daily')
    expect([routine.reload.seen_at, attention.reload.seen_at]).
      to all(be_present)
    expect(future.reload.seen_at).to be_nil
  end

  it 'serializes the sender per account without keeping a transaction open during mail' do
    _, _, notice, = response('REVIEW')
    # Checkout from the app pool so the advisory lock targets the test database
    # (DATABASE_URL omits the DB name and would lock the postgres database).
    pool = ActiveRecord::Base.connection_pool
    other = pool.checkout
    key = Digest::SHA256.hexdigest(
      "incoming_attention_notifications:#{user.id}"
    )[0, 16].to_i(16)
    key -= 2**64 if key >= 2**63
    other.execute("SELECT pg_advisory_lock(#{key})")
    expect(send_daily).to eq(false)
    expect(notice.reload.seen_at).to be_nil
    other.execute("SELECT pg_advisory_unlock(#{key})")
    during_render { expect(ActiveRecord::Base.connection.transaction_open?).to eq(false) }
    expect(send_daily).to eq(true)
  ensure
    # Disconnecting also drops the lock if the example failed holding it.
    if other
      pool.remove(other)
      other.disconnect!
    end
  end

  it 'leaves delivery failures unseen and emits only a fixed diagnostic code' do
    _, _, notice, = response('REVIEW')
    delivery = double('failed delivery', message: Mail.new(to: user.email))
    allow(delivery).
      to receive(:deliver_now).and_raise(StandardError,
                                         'secret provider response')
    allow(NotificationMailer).to receive(:daily_summary).and_return(delivery)
    allow(Rails.logger).to receive(:warn).and_call_original
    expect(Rails.logger).to receive(:warn).
      with('incoming_attention_notification_delivery_failed ' \
           "user_id=#{user.id} StandardError")
    expect(send_daily).to eq(false)
    expect(notice.reload.seen_at).to be_nil
  end

  it 'does not consume a real before_deliver abort' do
    _, _, notice, = response('REVIEW')
    callback = -> { throw(:abort) }
    NotificationMailer.before_deliver(callback)
    expect(send_daily).to eq(false)
    expect(ActionMailer::Base.deliveries).to be_empty
    expect(notice.reload.seen_at).to be_nil
  ensure
    NotificationMailer.skip_callback(:deliver, :before, callback) if callback
  end

  it 'does not consume a real delivery disabled by before_deliver' do
    _, _, notice, = response('REVIEW')
    callback = -> { message.perform_deliveries = false }
    NotificationMailer.before_deliver(callback)
    expect(send_daily).to eq(false)
    expect(ActionMailer::Base.deliveries).to be_empty
    expect(notice.reload.seen_at).to be_nil
  ensure
    NotificationMailer.skip_callback(:deliver, :before, callback) if callback
  end

  [:send_after, :seen_at, :expired].each do |field|
    it "rejects #{field} changes between rendering and delivery" do
      _, _, notice, = response('REVIEW')
      value = { send_after: 1.day.from_now,
                seen_at: Time.current,
                expired: true }.fetch(field)
      during_render { notice.update_columns(field => value) }
      expect(send_daily).to eq(false)
      expect(ActionMailer::Base.deliveries).to be_empty
    end
  end

  it 'rejects a source mutation between rendering and delivery' do
    _, message, notice, = response('REVIEW')
    during_render { message.update_columns(prominence: 'hidden') }
    expect(send_daily).to eq(false)
    expect(ActionMailer::Base.deliveries).to be_empty
    expect(notice.reload.seen_at).to be_nil
  end

  it 'leaves routine rows eligible if disabled during routine-only assembly' do
    _, _, notice, = response('SKIP')
    allow(described_class).
      to receive(:presentation).and_wrap_original do |original, *args|
      result = original.call(*args)
      allow(IncomingAttention::Config).to receive(:enabled?).and_return(false)
      result
    end
    send_daily
    expect(notice.reload.seen_at).to be_nil
    expect(NotificationMailer.send_daily_notifications).to eq(true)
    expect(notice.reload.seen_at).to be_present
  end
  it 'retains suppression across redeploys and releases an unsent reply after requester correction' do
    _, _message, notice, prediction = response('SKIP')
    prediction.update!(config_fingerprint: 'obsolete-release',
                       source_signature: 'obsolete-source')
    expect(send_daily).to eq(false)
    prediction.update!(attention_override: 'attention')
    travel_to(notice.reload.send_after + 1.second) do
      expect(send_daily).to eq(true)
      expect(notice.reload.seen_at).to be_present
      expect(send_daily).to eq(false)
    end
  end

  [true, false].each do |cached|
    context "with the query cache #{cached ? 'on' : 'off'}" do
      it 'holds an account with one prediction read and one Ability, however many rows it has' do
        few = FactoryBot.create(:user, trusted: true)
        many = FactoryBot.create(:user, trusted: true)
        4.times { response('SKIP', owner: few) }
        small = cost(cached: cached)
        20.times { response('SKIP', owner: many) }
        large = cost(cached: cached)

        expect(ActionMailer::Base.deliveries).to be_empty
        expect(large).to include(predictions: 1, abilities: 1)
        expect(large[:classified]).to eq(20)
        expect(large[:statements] - large[:classified]).
          to be <= small[:statements] - small[:classified],
             -> { "4 rows: #{small}, 20 rows: #{large}" }
        expect(large[:statements] - large[:classified]).
          to be <= 25, -> { large.to_s }
      end

      it 'sends a mixed summary with one prediction read and one Ability per pass, and one authority read' do
        owner = FactoryBot.create(:user, trusted: true)
        routes = %w[SKIP SKIP REVIEW REVIEW]
        messages = Array.new(5) do
          target = FactoryBot.create(:info_request, user: owner,
                                                    use_notifications: false)
          routes.map { |route|
            response(route, owner: owner, target: target)[1]
          }
        end
        messages.flatten.each(&:parse_raw_email) # as on arrival
        tally = cost(cached: cached)

        expect(ActionMailer::Base.deliveries.length).to eq(1)
        expect(Notification.where(user: owner, seen_at: nil)).to be_empty
        # Passes: choosing rows, the mailer's check and the check after
        # rendering. Only the first and last read predictions.
        expect(tally[:predictions]).to be <= 2, -> { tally.to_s }
        expect(tally[:abilities]).to be <= 3, -> { tally.to_s }
        expect(tally[:public_bodies]).to be <= 1, -> { tally.to_s }
      end
    end
  end
end
