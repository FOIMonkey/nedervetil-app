module IncomingAttention
  # Classifies one reply via the AI service and records the prediction.
  # State transitions use compare_and_update so a job that loses a race stops
  # without overwriting newer state.
  class Job < ApplicationJob
    queue_as :incoming_attention
    class_attribute :client_factory, default: -> { Client.new }
    ANALYSIS_WAIT_LIMIT = 24.hours
    def perform(prediction_id)
      return unless Config.enabled?

      prediction = Prediction.find_by(id: prediction_id)
      return unless prediction

      # Retries after storing a complete reading only re-apply classification.
      if prediction.status == 'complete'
        apply_classification(prediction.info_request)
        return
      end
      return unless %w[pending stale].include?(prediction.status)

      if OptOut.opted_out?(prediction.info_request&.user)
        restrict_opted_out(prediction)
        return
      end
      if prediction.attempts >= Config::MAX_ATTEMPTS
        give_up(prediction)
        return
      end
      return unless claim(prediction)

      message = read_reply(prediction)
      return unless message

      apply_classification(message.info_request)
      Outcome.queue(prediction, message)
    end

    private

    def restrict_opted_out(prediction)
      prediction.compare_and_update(status: 'restricted',
                                    error_code: 'opted_out',
                                    eligible: false,
                                    route: nil,
                                    needs_check: true,
                                    native_response: nil,
                                    reply_labels: nil)
    end

    def give_up(prediction)
      prediction.compare_and_update(status: 'failed',
                                    error_code: 'attempts_exhausted',
                                    eligible: false)
    end

    def claim(prediction)
      prediction.compare_and_update(status: 'running',
                                    attempts: prediction.attempts + 1)
    end

    def read_reply(prediction)
      request_id = prediction.info_request_id
      message = prediction.incoming_message
      snapshot = snapshot_to_send(message, request_id)
      response = self.class.client_factory.call.classify(snapshot.request)
      # Switched off during the call: the answer is not stored.
      return unless Config.enabled?

      ensure_still_available!(message, request_id)
      attributes = reading_attributes(response, snapshot)
      message if prediction.compare_and_update(attributes)
    rescue Input::Unavailable => error
      if error.code == 'analysis_pending'
        defer_analysis(prediction, error.code)
      else
        failure(prediction, error.code, 'restricted')
      end
      nil
    rescue Client::Error => error
      failure(prediction,
              error.code,
              error.status == 'input_limit' ? 'input_limit' : 'failed')
      nil
    rescue StandardError => error
      # The class only: the message can carry the reply's text.
      Rails.logger.warn('incoming_attention_unexpected_failure ' \
                        "prediction_id=#{prediction.id} #{error.class}")
      failure(prediction, 'unexpected_failure', 'failed')
      nil
    end

    # Re-checks request ownership and opt-out before sending to the AI service.
    def snapshot_to_send(message, request_id)
      snapshot = Input.build(message)
      unless snapshot.info_request_id == request_id
        raise Input::Unavailable, 'source_unavailable'
      end

      OptOut.guard!(message.info_request.reload)
      snapshot
    end

    # Guard against the reply being hidden, erased or moved during the AI call.
    def ensure_still_available!(message, request_id)
      return if Input.available?(message.reload) &&
                message.info_request_id == request_id

      raise Input::Unavailable, 'source_unavailable'
    end

    def reading_attributes(response, snapshot)
      complete = complete?(response)
      restrictions = restrictions_on(response, snapshot)
      {
        status: status_for(response),
        response_event_id: snapshot.response_event_id,
        route: complete ? response['route'] : nil,
        needs_check: complete ? response['needs_check'] : true,
        native_response: complete ? response['diagnostics'] : nil,
        reply_labels: complete ? response['labels'] : nil,
        eligible: complete && response['eligibility'] && restrictions.empty?,
        restrictions: restrictions,
        error_code: response['error_code'],
        predicted_at: Time.current,
        coverage_verified: false,
        lease_token: nil,
        lease_expires_at: nil
      }
    end

    def complete?(response)
      response['inference_status'] == 'complete'
    end

    def status_for(response)
      if complete?(response)
        'complete'
      elsif response['inference_status'] == 'input_limit'
        'input_limit'
      else
        'failed'
      end
    end

    # Ensure ineligible complete readings always carry at least one restriction.
    def restrictions_on(response, snapshot)
      complete = complete?(response)
      restrictions =
        (complete && response['input_truncated'] ? ['input_truncated'] : []) +
        snapshot.restrictions
      if complete && !response['eligibility'] && restrictions.empty?
        restrictions += ['unsupported_input']
      end
      restrictions
    end

    def apply_classification(request)
      Classification.apply(request)
    rescue StandardError
      Rails.logger.warn('incoming_attention_classification_failed')
      raise 'incoming_attention_classification_failed'
    end

    def defer_analysis(prediction, code)
      age = analysis_wait_age(prediction)
      if age >= ANALYSIS_WAIT_LIMIT
        failure(prediction, 'source_unavailable', 'restricted')
        return
      end

      wait = analysis_wait(age)
      restored = [prediction.attempts - 1, 0].max
      return unless prediction.compare_and_update(
        status: wait ? 'pending' : 'restricted',
        attempts: restored,
        error_code: code
      )

      self.class.set(wait: wait).perform_later(prediction.id) if wait
    end

    def analysis_wait_age(prediction)
      message = prediction.incoming_message
      since = Input.waiting_for_analysis_since(message)
      return Time.current - since if since
      return 0 if Input.available?(message)

      Time.current - prediction.created_at
    end

    def analysis_wait(age)
      return 15.seconds if age < 2.minutes
      return 2.minutes if age < 15.minutes

      nil
    end

    def failure(prediction, code, status)
      return unless prediction.compare_and_update(status: status,
                                                  eligible: false,
                                                  route: nil,
                                                  needs_check: true,
                                                  native_response: nil,
                                                  reply_labels: nil,
                                                  error_code: code)

      Rails.logger.warn('incoming_attention_check_failed ' \
                        "prediction_id=#{prediction.id} code=#{code}")
    end
  end
end
