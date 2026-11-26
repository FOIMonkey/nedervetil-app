module IncomingAttention
  module Outcome
    # Assesses one reply's outcome. Prediction.move_outcome fences writes on
    # outcome_checked_at so a late job cannot overwrite state after
    # invalidation or recovery.
    class Job < ApplicationJob
      queue_as :incoming_attention
      class_attribute :client_factory, default: -> { Client.new }

      def perform(prediction_id)
        return unless Outcome.active?

        row = Prediction.find_by(id: prediction_id) or return
        if row.outcome_status == 'complete'
          return Outcome.apply(row.info_request)
        end

        attempts = row.outcome_attempts + 1
        claim = Prediction.move_outcome(row.id, 'pending',
                                        row.outcome_checked_at,
                                        outcome_status: 'running',
                                        outcome_attempts: attempts)
        return unless claim

        assess_and_settle(row, claim, attempts)
        Outcome.apply(row.reload.info_request)
      end

      private

      def assess_and_settle(row, claim, attempts)
        message = row.incoming_message
        OptOut.guard!(message.info_request)
        built = Input.build(message)
        Input.recheck!(message, built)
        result = Outcome.floor(
          self.class.client_factory.call.assess(built.request),
          built.request
        )
        # The Worker's diagnostics are kept for evaluation, not read here.
        diagnostics = result['diagnostics'] || {}
        signals =
          (diagnostics['signals'].is_a?(Hash) ? diagnostics['signals'] : {}).
            merge(built.signals).
            merge(result.slice('reasons', 'withheld_under', 'mentions')).
            merge('truncated' => result['input_truncated'])
        settle(row, claim, outcome_status: 'complete',
                           outcome_scores: diagnostics['scores'],
                           outcome_signals: signals,
                           outcome_call: result['call'])
      rescue IncomingAttention::Input::Unavailable => error
        if error.code == 'analysis_pending'
          defer_analysis(row, claim, attempts)
          return
        end

        retry_later = error.code == 'masking_pending' &&
                      attempts < MAX_ATTEMPTS
        finish(row, claim, retry_later ? 'pending' : 'restricted',
               error.code)
      rescue Client::Error => error
        finish(
          row, claim,
          error.retryable && attempts < MAX_ATTEMPTS ? 'pending' : 'failed',
          error.code
        )
      rescue StandardError => e
        finish(row, claim, 'failed', 'unexpected_failure', e)
      end

      def defer_analysis(row, claim, attempts)
        age = analysis_wait_age(row)
        if age >= IncomingAttention::Job::ANALYSIS_WAIT_LIMIT
          finish(row, claim, 'restricted', 'source_unavailable')
          return
        end

        wait = analysis_wait(age)
        restored = [attempts - 1, 0].max
        return unless settle(row, claim,
                             outcome_status: 'pending',
                             outcome_attempts: restored,
                             outcome_signals: { 'error' => 'analysis_pending' },
                             outcome_call: nil)

        self.class.set(wait: wait).perform_later(row.id) if wait
      end

      def analysis_wait_age(row)
        message = row.incoming_message
        since = IncomingAttention::Input.waiting_for_analysis_since(message)
        return Time.current - since if since
        return 0 if IncomingAttention::Input.available?(message)

        Time.current - row.created_at
      end

      def analysis_wait(age)
        return 15.seconds if age < 2.minutes
        return 2.minutes if age < 15.minutes

        nil
      end

      # Logs only error.class on unexpected errors to avoid leaking reply text.
      def finish(row, claim, status, code, error = nil)
        settle(row, claim, outcome_status: status,
                           outcome_signals: { 'error' => code },
                           outcome_call: nil)
        cause = " #{error.class}" if error
        Rails.logger.warn('request_outcome_check_failed ' \
                          "prediction_id=#{row.id} code=#{code}#{cause}")
      end

      def settle(row, claim, attributes)
        Prediction.move_outcome(row.id, 'running', claim, attributes)
      end
    end
  end
end
