module IncomingAttention
  # Runs apart from the AI consumer, so a stopped worker can't stop recovery.
  module Recovery
    RETRYABLE = %w[
      enqueue_failed
      transport_failure
      provider_timeout
      provider_failure
      unexpected_failure
    ].freeze
    def self.run(limit: 100)
      return 0 unless Config.enabled?

      # Receipt creates its row transactionally. Missing rows are historical
      # mail, so creating checks for them requires an explicit backfill cutoff.
      if (cutoff = Config.backfill_received_after)
        missing = Effective.unresolved.
          where.not(iaowner_request: { url_title: 'holding_pen' }).
          where('incoming_messages.created_at >= ?', cutoff).
          where.not(id: Prediction.select(:incoming_message_id)).
          order(:id).limit(limit)
        missing.each { |message| Prediction.ensure_for(message)&.enqueue! }
      end
      rows = Prediction.where('updated_at < ?', 5.minutes.ago).
        where(status: %w[pending running stale]).or(
          Prediction.where('updated_at < ?', 5.minutes.ago).
            where(status: 'failed', error_code: RETRYABLE)
        ).or(
          Prediction.where('updated_at < ?', 5.minutes.ago).
            where(status: 'restricted',
                  error_code: %w[masking_pending analysis_pending])
        ).
        order(:updated_at).limit(limit).to_a
      rows.each { |row| recover_row(row) }
      rows.size + outcomes(limit)
    end

    def self.recover_row(row)
      if row.attempts >= Config::MAX_ATTEMPTS
        if row.compare_and_update(status: 'failed',
                                  error_code: 'attempts_exhausted',
                                  eligible: false,
                                  needs_check: true,
                                  route: nil,
                                  native_response: nil,
                                  reply_labels: nil)
          Rails.logger.warn('incoming_attention_recovery_exhausted ' \
                            "prediction_id=#{row.id}")
        end
      elsif !Input.available?(row.incoming_message)
        since = Input.waiting_for_analysis_since(row.incoming_message)
        if since && since > IncomingAttention::Job::ANALYSIS_WAIT_LIMIT.ago
          row.compare_and_update(status: 'restricted',
                                 error_code: 'analysis_pending')
          return
        end

        row.compare_and_update(status: 'restricted',
                               eligible: false,
                               error_code: 'source_unavailable',
                               needs_check: true,
                               route: nil,
                               native_response: nil,
                               reply_labels: nil)
      elsif row.compare_and_update(status: 'pending')
        row.enqueue!
      end
    end

    def self.outcomes(limit)
      return 0 unless Outcome.active?

      rows = Prediction.where(outcome_status: %w[pending running]).
        where('outcome_checked_at < ?', 10.minutes.ago).
        order(:outcome_checked_at).limit(limit).to_a
      rows.each { |row| recover_outcome(row) }
      rows.size
    end

    def self.recover_outcome(row)
      if row.outcome_attempts >= Outcome::MAX_ATTEMPTS
        Prediction.move_outcome(
          row.id, row.outcome_status, row.outcome_checked_at,
          outcome_status: 'failed',
          outcome_signals: { 'error' => 'attempts_exhausted' }
        )
      elsif !Input.available?(row.incoming_message)
        since = Input.waiting_for_analysis_since(row.incoming_message)
        if since && since > IncomingAttention::Job::ANALYSIS_WAIT_LIMIT.ago
          Prediction.move_outcome(
            row.id, row.outcome_status, row.outcome_checked_at,
            outcome_signals: { 'error' => 'analysis_pending' }
          )
          return
        end

        Prediction.move_outcome(
          row.id, row.outcome_status, row.outcome_checked_at,
          outcome_status: 'restricted',
          outcome_signals: { 'error' => 'source_unavailable' },
          outcome_call: nil
        )
      elsif Prediction.move_outcome(row.id, row.outcome_status,
                                    row.outcome_checked_at,
                                    outcome_status: 'pending')
        Outcome::Job.perform_later(row.id)
      end
    end
  end
end
