# == Schema Information
#
# Table name: incoming_attention_predictions
#
#  id                      :bigint           not null, primary key
#  incoming_message_id     :bigint           not null
#  info_request_id         :bigint           not null
#  response_event_id       :bigint
#  status                  :string           default("pending"), not null
#  route                   :string
#  needs_check             :boolean
#  eligible                :boolean          default(FALSE), not null
#  coverage_verified       :boolean          default(FALSE), not null
#  native_response         :jsonb
#  restrictions            :jsonb            not null
#  input_fingerprint       :string
#  state_sha256            :string
#  source_revision_sha256  :string
#  source_signature        :string
#  config_fingerprint      :string
#  error_code              :string
#  generation              :bigint           default(0), not null
#  attempts                :integer          default(0), not null
#  lease_token             :string
#  lease_expires_at        :datetime
#  predicted_at            :datetime
#  created_at              :datetime         not null
#  updated_at              :datetime         not null
#  attention_override      :string
#  human_reviewed_at       :datetime
#  auto_classified         :boolean          default(FALSE), not null
#  outcome_status          :string
#  outcome_attempts        :integer          default(0), not null
#  outcome_scores          :jsonb
#  outcome_signals         :jsonb
#  outcome_call            :string
#  outcome_applied_state   :string
#  outcome_overridden_from :string
#  outcome_checked_at      :datetime
#  reply_labels            :jsonb
#

module IncomingAttention
  # The AI reading of one reply, with the state of its check and any person's
  # choice.
  class Prediction < ApplicationRecord
    self.table_name = 'incoming_attention_predictions'
    belongs_to :incoming_message
    belongs_to :info_request
    belongs_to :response_event, class_name: 'InfoRequestEvent', optional: true
    validates :status, inclusion: {
      in: %w[pending running complete failed input_limit restricted stale]
    }
    validates :route,
              inclusion: { in: %w[SKIP REVIEW ADMIN_SUPPORT] },
              allow_nil: true
    validates :attention_override,
              inclusion: { in: %w[attention routine] },
              allow_nil: true
    def self.ensure_for(message)
      return unless Config.enabled?
      return if message.info_request.holding_pen_request?(read_only: true)

      create_or_find_by!(incoming_message_id: message.id) do |row|
        row.info_request_id = message.info_request_id
      end
    end

    def self.for_message(message)
      return unless Config.enabled?

      Current.memo(:prediction, message.id) do
        find_by(incoming_message_id: message.id)
      end
    end

    # Batch-populates Current.page_memo for a thread; no-op outside a page.
    def self.remember_for(message_ids)
      return unless Config.enabled? && Current.page_memo

      rows = where(incoming_message_id: message_ids).
        index_by(&:incoming_message_id)
      message_ids.each do |id|
        Current.memo(:prediction, id) { rows[id] }
      end
    end

    # Marks prediction stale after source/visibility changes, syncs
    # info_request_id, and re-enqueues after commit if still available.
    def self.invalidate_message(message_id, reason)
      row = find_by(incoming_message_id: message_id)
      return unless row

      row.invalidate!(reason: reason)
      message = IncomingMessage.find_by(id: message_id)
      if message
        row.update!(info_request_id: message.info_request_id,
                    response_event_id: nil)
      end
      ActiveRecord.after_all_transactions_commit do
        row.enqueue! if message && Input.available?(message)
      end
    end

    def eligible?
      status == 'complete' && eligible && restrictions == []
    end

    def truncated?
      restrictions.include?('input_truncated')
    end

    def current?(message = incoming_message)
      status == 'complete' && info_request_id == message.info_request_id
    end

    # Monotonic microsecond CAS stamp; advances by >=1us even if the clock
    # stalls or steps back.
    def self.next_stamp(previous)
      now = Time.current
      now = now.change(nsec: (now.nsec / 1_000) * 1_000)
      previous ? [now, previous + Rational(1, 1_000_000)].max : now
    end

    # CAS transition for outcome state keyed on (outcome_status,
    # outcome_checked_at); invalidation preserves the stamp so stale jobs/
    # recovery passes cannot overwrite. Returns the new stamp or nil.
    def self.move_outcome(id, status, stamp, attributes)
      next_stamp = next_stamp(stamp)
      moved = where(id: id, outcome_status: status, outcome_checked_at: stamp).
        update_all(attributes.merge(outcome_checked_at: next_stamp)) == 1
      next_stamp if moved
    end

    # updated_at is a compare-and-set stamp for check state only; human choices
    # do not advance it.
    def compare_and_update(attributes)
      stamp = self.class.next_stamp(updated_at)
      changed = self.class.where(id: id,
                                 status: status,
                                 updated_at: updated_at,
                                 info_request_id: info_request_id).
        update_all(attributes.merge(updated_at: stamp)) == 1
      reload if changed
      changed
    end

    def enqueue!
      return false unless Config.enabled? && %w[pending stale].include?(status)
      return false unless compare_and_update({})
      raise 'enqueue_failed' unless Job.perform_later(id)

      true
    rescue StandardError => e
      count = attempts + 1
      if persisted?
        compare_and_update(
          error_code: 'enqueue_failed',
          attempts: count,
          status: count >= Config::MAX_ATTEMPTS ? 'failed' : status
        )
      end
      Rails.logger.warn('incoming_attention_enqueue_failed ' \
                        "prediction_id=#{id} #{e.class}")
      false
    end

    # purge_payloads is ignored; stale predictions always purge payloads.
    def invalidate!(reason: 'visibility_changed', purge_payloads: false) # rubocop:disable Lint/UnusedMethodArgument
      with_lock do
        compare_and_update(status: 'stale',
                           eligible: false,
                           route: nil,
                           needs_check: true,
                           native_response: nil,
                           reply_labels: nil,
                           restrictions: [],
                           attention_override: nil,
                           attempts: 0,
                           input_fingerprint: nil,
                           state_sha256: nil,
                           source_revision_sha256: nil,
                           source_signature: nil,
                           config_fingerprint: nil,
                           error_code: reason,
                           lease_token: nil,
                           lease_expires_at: nil,
                           outcome_status: nil,
                           outcome_attempts: 0,
                           outcome_scores: nil,
                           outcome_signals: nil,
                           outcome_call: nil)
      end
    end
  end
end
