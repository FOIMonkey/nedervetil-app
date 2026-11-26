module IncomingAttention
  module Outcome
    # Validates outcome responses against the request sent to the Worker.
    class Client
      Error = IncomingAttention::Client::Error
      FIELDS = %w[
        contract_version
        message_id
        info_request_id
        request_text
        request_shortened
        reply
        reply_unfolded
        documents
        text_shortened
        omitted_documents
        cited_sections
        strict_documents
      ].freeze
      MAX_RESPONSE_BYTES = 16_384
      CODE = /\A[a-z_]{1,40}\z/

      def initialize(transport: nil)
        @transport = transport
      end

      def assess(input)
        unless Config.enabled?
          raise Error.new('disabled', status: 'unavailable')
        end
        unless input.is_a?(Hash) && (FIELDS - input.keys).empty?
          raise Error, 'invalid_request'
        end

        body = JSON.generate(input)
        if body.bytesize > Config::MAX_REQUEST_BYTES
          raise Error.new('request_limit', status: 'input_limit')
        end

        status, bytes = post(input, body)
        unless bytes.is_a?(String) && bytes.bytesize <= MAX_RESPONSE_BYTES
          raise Error, 'response_limit'
        end

        response = JSON.parse(bytes)
        validate!(response, input, status)
      rescue Error
        raise
      rescue JSON::ParserError, JSON::GeneratorError, EncodingError
        raise Error, 'invalid_worker_response'
      rescue StandardError => e
        Rails.logger.warn("request_outcome_assess_failed #{e.class}")
        raise Error.new('transport_failure',
                        status: 'unavailable',
                        retryable: true)
      end

      private

      def post(input, body)
        if @transport
          @transport.call(input)
        else
          Transport.new.post(body, path: '/v1/outcome')
        end
      end

      def validate!(response, input, status)
        invalid = -> { raise Error, 'invalid_worker_response' }
        unless response.is_a?(Hash) &&
               %w[contract_version message_id info_request_id].
                 all? { |key| response[key] == input[key] }
          invalid.call
        end
        unless response['inference_status'] == 'complete' && status == 200
          worker_error!(response, status, invalid)
        end
        # Names shown to the requester: only the codes in NAMES and the sections
        # sent. Anything else means the Worker is not answering what it was
        # asked, so the reading is refused.
        names = NAMES.keys + Array(input['cited_sections'])
        invalid.call unless lists_ok?(response, names)
        invalid.call unless flags_ok?(response, input)
        response
      end

      def worker_error!(response, status, invalid)
        code = response['error_code'].to_s
        unless code.match?(/\A[a-z_]{1,60}\z/) && response['call'].nil?
          invalid.call
        end
        raise Error.new(
          code,
          status: [503, 504].include?(status) ? 'unavailable' : 'failed',
          retryable: [502, 503, 504].include?(status)
        )
      end

      def lists_ok?(response, names)
        CALLS.include?(response['call']) &&
          list?(response['reasons']) { |item| item.match?(CODE) } &&
          list?(response['withheld_under']) { |item| names.include?(item) } &&
          list?(response['mentions']) { |item| names.include?(item) }
      end

      def flags_ok?(response, input)
        [true, false].include?(response['input_truncated']) &&
          !(input['text_shortened'] && !response['input_truncated']) &&
          response['error_code'].nil? &&
          (response['diagnostics'].nil? || response['diagnostics'].is_a?(Hash))
      end

      def list?(value)
        value.is_a?(Array) && value.size <= 40 &&
          value.all? { |item| item.is_a?(String) && yield(item) }
      end
    end
  end
end
