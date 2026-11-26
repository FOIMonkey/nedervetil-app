require 'spec_helper'
require 'timeout'

RSpec.describe RequestLimits do
  include_context 'with request limits on, on the real clock'
  include_context 'with incoming attention off' if defined?(IncomingAttention::Config)

  let(:user) { FactoryBot.create(:user) }

  def make_request(owner = user)
    FactoryBot.create(:info_request, user: owner)
  end

  def followup(request)
    FactoryBot.create(:new_information_followup, info_request: request)
  end

  def refused(kind)
    raise_error(RequestLimits::Exceeded) do |error|
      expect(error.refusal.kind).to eq(kind)
    end
  end

  describe 'new requests' do
    it 'allows one a minute' do
      make_request
      expect { make_request }.to refused(:request)
      expect(user.info_requests.count).to eq(1)
      travel 61.seconds
      expect { make_request }.not_to raise_error
    end

    it 'allows three in any 24 hours, from the first of them' do
      # A stopped clock, so the first request is sent at `first` exactly.
      travel_to Time.current
      first = Time.current
      3.times do
        make_request
        travel 2.minutes
      end
      expect { make_request }.to raise_error(RequestLimits::Exceeded) { |error|
        expect(error.refusal.window).to eq(24.hours)
        expect(error.refusal.available_at).
          to be_within(1.second).of(first + 24.hours)
      }
      travel_to first + 24.hours + 1.second
      expect { make_request }.not_to raise_error
    end

    it 'allows ten in any 30 days' do
      10.times do
        make_request
        travel 25.hours
      end
      expect { make_request }.to raise_error(RequestLimits::Exceeded) { |error|
        expect(error.refusal.window).to eq(30.days)
      }
    end

    it 'gives nothing back when requests are deleted' do
      requests = Array.new(3) { make_request.tap { travel 2.minutes } }
      requests.each(&:destroy!)
      expect { make_request }.to refused(:request)
      expect(RequestLimits::Send.where(user_id: user.id).count).to eq(3)
    end

    it 'exempts accounts with "No rate limit" and admins' do
      [FactoryBot.create(:user, trusted: true),
       FactoryBot.create(:admin_user)].each do |owner|
        expect { 4.times { make_request(owner) } }.not_to raise_error
      end
    end

    it 'is off outside production unless switched on, and on in production unless the setting turns it off' do
      with_setting(RequestLimits, :enforced, false) do
        expect { 2.times { make_request } }.not_to raise_error
        allow(Rails.env).to receive(:production?).and_return(true)
        expect(described_class).to be_enforced
        allow(AlaveteliConfiguration).
          to receive(:enforce_request_limits).and_return(false)
        expect(described_class).not_to be_enforced
      end
    end

    it 'keeps no text, and drops rows older than 31 days as new ones are written' do
      expect(described_class::Send.column_names).
        to contain_exactly('id', 'user_id', 'kind', 'info_request_id',
                           'created_at')
      make_request
      travel 32.days
      make_request(FactoryBot.create(:user))
      expect(described_class::Send.where(user_id: user.id)).to be_empty
    end

    it 'says which limit was reached and when the next request can go' do
      travel_to Time.zone.local(2026, 10, 22, 14, 20, 30)
      make_request
      refusal = described_class.refusal(user, :request)
      expect(RequestLimits::Text.reason(refusal)).
        to eq('You’ve sent a request in the last minute.')
      expect(RequestLimits::Text.
               when_label(RequestLimits::Text.available_at(refusal))).
        to eq('2:22pm today')
      travel 2.minutes
      2.times do
        make_request
        travel 2.minutes
      end
      refusal = described_class.refusal(user, :request)
      expect(RequestLimits::Text.reason(refusal)).
        to eq('You’ve sent 3 requests in the last 24 hours.')
      expect(RequestLimits::Text.
               when_label(RequestLimits::Text.available_at(refusal))).
        to eq('2:21pm on Friday 23 October')
    end
  end

  describe 'follow-ups' do
    let(:request) { without_limits { make_request } }

    it 'allows three on one request in five minutes' do
      3.times do
        followup(request)
        travel 1.minute
      end
      expect { followup(request) }.
        to raise_error(RequestLimits::Exceeded) { |error|
          expect(error.refusal.per_request).to be(true)
        }
      travel 3.minutes
      expect { followup(request) }.not_to raise_error
    end

    it 'allows 25 in any 30 days, internal reviews and clarifications included' do
      24.times do
        followup(request)
        travel 2.minutes
      end
      FactoryBot.create(:internal_review_request, info_request: request)
      travel 2.minutes
      expect { followup(request) }.
        to raise_error(RequestLimits::Exceeded) { |error|
          expect(error.refusal.window).to eq(30.days)
        }
    end

    it 'does not count the first message of a request' do
      make_request
      expect(RequestLimits::Send.where(user_id: user.id).pluck(:kind)).
        to eq(['request'])
    end
  end

  describe 'batches' do
    let(:bodies) { FactoryBot.create_list(:public_body, 3) }

    def make_batch(owner = user, public_bodies: bodies)
      FactoryBot.create(:info_request_batch, user: owner,
                                             public_bodies: public_bodies)
    end

    it 'needs a trusted account' do
      expect { make_batch }.to raise_error(RequestLimits::BatchesOff)
      user.update!(trusted: true)
      expect { make_batch }.not_to raise_error
    end

    it 'lets an admin make batches, as admins are trusted' do
      expect { make_batch(FactoryBot.create(:admin_user)) }.not_to raise_error
    end

    it 'caps every batch at 50 authorities, even a trusted account’s, and limits nothing else' do
      user.update!(trusted: true)
      expect {
        make_batch(public_bodies: FactoryBot.create_list(:public_body, 51))
      }.to refused(:batch_authorities)
      3.times { make_batch }
      expect(user.info_request_batches.count).to eq(3)
      expect(RequestLimits.batch_authority_limit).to eq(50)
    end

    it 'does not count a batch’s requests against the request limits' do
      user.update!(trusted: true)
      make_batch.create_batch!
      expect(user.info_requests.count).to eq(3)
      expect(RequestLimits::Send.where(user_id: user.id).count).to eq(0)
    end

    it 'leaves a batch unsent once its account is no longer trusted' do
      allowed = FactoryBot.create(:user, trusted: true)
      kept = make_batch(allowed)
      user.update!(trusted: true)
      held = make_batch
      user.update!(trusted: false)
      InfoRequestBatch.send_batches
      expect(kept.reload.sent_at).to be_present
      expect(held.reload.sent_at).to be_nil
      expect(held.info_requests).to be_empty
    end

    it 'keeps batches to trusted accounts in production when the setting turns the caps off' do
      user.update!(trusted: true)
      held = make_batch
      user.update!(trusted: false)
      with_setting(RequestLimits, :enforced, false) do
        allow(Rails.env).to receive(:production?).and_return(true)
        allow(AlaveteliConfiguration).
          to receive(:enforce_request_limits).and_return(false)
        expect(described_class).not_to be_enforced
        expect(described_class.batches_allowed?(user)).to be(false)
        InfoRequestBatch.send_batches
        expect(held.reload.sent_at).to be_nil
      end
    end
  end
end

RSpec.describe 'Request limits under simultaneous submissions' do
  self.use_transactional_tests = false
  include_context 'with request limits on, on the real clock'
  include_context 'with incoming attention off' if defined?(IncomingAttention::Config)

  # Follow-ups to two different requests: nothing else in their creation locks
  # a shared row, so only RequestLimits' lock on the account can order them.
  it 'lets only one of two follow-ups sent at the same moment through when one place is left' do
    user = FactoryBot.create(:user)
    requests = without_limits do
      FactoryBot.create_list(:info_request, 2, user: user)
    end
    (RequestLimits::FOLLOWUPS[30.days] - 1).times do |n|
      RequestLimits::Send.create!(user_id: user.id,
                                  kind: 'followup',
                                  created_at: (n + 10).minutes.ago)
    end
    ready = Queue.new
    proceed = Queue.new
    allow(RequestLimits).
      to receive(:refusal).and_wrap_original do |original, *args, **options|
      if Thread.current[:hold_after_lock]
        ready << true
        Timeout.timeout(10) { proceed.pop }
      end
      original.call(*args, **options)
    end
    send = ->(request, hold) do
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          Thread.current[:hold_after_lock] = hold
          FactoryBot.create(:new_information_followup, info_request: request)
          :sent
        rescue RequestLimits::Exceeded
          :refused
        end
      end
    end
    first = send.call(requests[0], true)
    Timeout.timeout(10) { ready.pop }
    second = send.call(requests[1], false)
    Timeout.timeout(10) do
      sleep 0.05 until ActiveRecord::Base.connection.select_value(
        "SELECT count(*) FROM pg_stat_activity WHERE wait_event_type = 'Lock'"
      ).to_i.positive?
    end
    proceed << true
    expect([first, second].map { |thread| thread.join(15).value }).
      to contain_exactly(:sent, :refused)
    expect(OutgoingMessage.where(info_request_id: requests.map(&:id),
                                 message_type: 'followup').count).to eq(1)
  ensure
    proceed&.<<(true)
    requests&.each { |request| request.reload.destroy! }
    RequestLimits::Send.where(user_id: user&.id).delete_all
    user&.destroy!
  end

  # Each insert takes a KEY SHARE lock on the account row for its foreign key,
  # and the user's info_requests_count counter cache then updates the row, so
  # RequestLimits' lock on the row must not conflict with KEY SHARE: FOR UPDATE
  # deadlocks here, and FOR NO KEY UPDATE queues them.
  it 'lets only one of two new requests sent at the same moment through, without a deadlock' do
    user = FactoryBot.create(:user)
    bodies = FactoryBot.create_list(:public_body, 2)
    ready = Queue.new
    proceed = Queue.new
    allow(RequestLimits).
      to receive(:record!).and_wrap_original do |original, *args, **options|
      if Thread.current[:hold_before_lock]
        ready << true
        Timeout.timeout(10) { proceed.pop }
      end
      original.call(*args, **options)
    end
    send = ->(hold, body, title) do
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          Thread.current[:hold_before_lock] = hold
          FactoryBot.create(:info_request, user: user,
                                           public_body: body,
                                           title: title)
          :sent
        rescue RequestLimits::Exceeded
          :refused
        end
      end
    end
    first = send.call(true, bodies[0], 'Gritting routes 2025')
    Timeout.timeout(10) { ready.pop }
    second = send.call(false, bodies[1], 'Bin collection rounds 2025')
    Timeout.timeout(10) do
      sleep 0.05 until ActiveRecord::Base.connection.select_value(
        "SELECT count(*) FROM pg_stat_activity WHERE wait_event_type = 'Lock'"
      ).to_i.positive?
    end
    proceed << true
    expect([first, second].map { |thread| thread.join(15).value }).
      to contain_exactly(:sent, :refused)
    expect(InfoRequest.where(user_id: user.id).count).to eq(1)
  ensure
    proceed&.<<(true)
    InfoRequest.where(user_id: user&.id).find_each(&:destroy!)
    bodies&.each { |body| body.reload.destroy! }
    RequestLimits::Send.where(user_id: user&.id).delete_all
    user&.destroy!
  end
end
