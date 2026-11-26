require 'json'

module IncomingAttention
  # Sends a reply to the AI service and validates the reading it returns.
  class Client
    # Client error carrying error code, prediction status, and retryability.
    class Error < StandardError
      attr_reader :code, :status, :retryable

      def initialize(code, status: 'failed', retryable: false)
        @code = code
        @status = status
        @retryable = retryable
        super(code)
      end
    end
    STATUSES = { 'complete' => [200],
                 'input_limit' => [413],
                 'unavailable' => [503, 504],
                 'failed' => [502],
                 'invalid_input' => [400, 415] }.freeze
    LABELS = { 'routine' => [nil, 'ACKNOWLEDGEMENT'],
               'attention' => [nil, 'DELIVERY_PROBLEM', 'ACTION_REQUESTED',
                               'DECISION', 'SUBSTANTIVE'] }.freeze
    def initialize(transport: nil)
      @transport = transport
    end

    def classify(input)
      raise Error.new('disabled', status: 'unavailable') unless Config.enabled?
      unless input.is_a?(Hash) && (Config::REQUEST_FIELDS - input.keys).empty?
        raise Error, 'invalid_request'
      end

      body = JSON.generate(input)
      if body.bytesize > Config::MAX_REQUEST_BYTES
        raise Error.new('request_limit', status: 'input_limit')
      end

      status, bytes = if @transport
                        @transport.call(input)
                      else
                        Transport.new.post(body)
                      end
      unless bytes.is_a?(String) && bytes.bytesize <= Config::MAX_RESPONSE_BYTES
        raise Error, 'response_limit'
      end

      response = JSON.parse(bytes)
      validate!(response, input, status)
      response
    rescue Error
      raise
    rescue JSON::ParserError, JSON::GeneratorError, EncodingError
      raise Error, 'invalid_worker_response'
    rescue StandardError => e
      Rails.logger.warn("incoming_attention_classify_failed #{e.class}")
      raise Error.new('transport_failure',
                      status: 'unavailable',
                      retryable: true)
    end

    private

    # Worker diagnostics are stored for evaluation only, never interpreted.
    def validate!(response, input, status)
      invalid = -> { raise Error, 'invalid_worker_response' }
      invalid.call unless envelope_ok?(response, status)
      %w[contract_version message_id info_request_id].each do |key|
        invalid.call unless response[key] == input[key]
      end
      invalid.call unless route_ok?(response)
      if response['inference_status'] != 'complete'
        invalid.call unless error_shape_ok?(response)
        return response
      end
      invalid.call unless truncation_ok?(response, input)
      labels = response['labels']
      invalid.call unless labels_ok?(labels)
      invalid.call unless diagnostics_ok?(response)
      response
    end

    def envelope_ok?(response, status)
      response.is_a?(Hash) &&
        STATUSES.fetch(response['inference_status'], []).include?(status)
    end

    def route_ok?(response)
      [true, false].include?(response['eligibility']) &&
        %w[SKIP REVIEW ADMIN_SUPPORT].include?(response['route']) &&
        response['needs_check'] == (response['route'] != 'SKIP')
    end

    def error_shape_ok?(response)
      response['eligibility'] == false &&
        response['needs_check'] == true &&
        response['labels'].nil? && response['diagnostics'].nil? &&
        response['error_code'].is_a?(String) &&
        response['error_code'].match?(/\A[a-z_]{1,60}\z/)
    end

    def truncation_ok?(response, input)
      truncated = response['input_truncated']
      response['error_code'].nil? &&
        [true, false].include?(truncated) &&
        !(truncated && response['eligibility']) &&
        !(input['body_shortened'] && !truncated)
    end

    def labels_ok?(labels)
      labels.is_a?(Hash) && labels.keys.sort == LABELS.keys.sort &&
        LABELS.all? { |key, values| values.include?(labels[key]) }
    end

    def diagnostics_ok?(response)
      response['diagnostics'].nil? || response['diagnostics'].is_a?(Hash)
    end
  end
end
