require 'json'
require 'time'

module IncomingAttention
  # Settings and limits for AI reading.
  module Config
    # Stable API contract version so deployments do not expire stored readings.
    CONTRACT = { 'contract_version' => 'incoming-attention/v5' }.freeze
    REQUEST_FIELDS = %w[
      contract_version
      message_id
      info_request_id
      body
      body_shortened
      attachments
    ].freeze
    MAX_REQUEST_BYTES = 65_536
    MAX_RESPONSE_BYTES = 131_072
    MAX_ATTEMPTS = 5

    module_function

    def enabled?
      AlaveteliConfiguration.incoming_attention_enabled == true
    end

    # Opt-in backfill cutoff; compared against receipt time, never Date header.
    def backfill_received_after
      value = AlaveteliConfiguration.incoming_attention_backfill_received_after
      unless value.is_a?(String) && value.match?(/(?:Z|[+-]\d{2}:\d{2})\z/)
        return
      end

      Time.iso8601(value)
    rescue ArgumentError
      nil
    end

    def endpoint
      AlaveteliConfiguration.incoming_attention_endpoint.to_s
    end

    # Read from ENV so only calling processes hold the secret.
    def token
      ENV['INCOMING_ATTENTION_AUTH_TOKEN'].to_s
    end

    def contract
      { 'contract_version' => CONTRACT.fetch('contract_version') }
    end

    def anonymiser_endpoint
      AlaveteliConfiguration.incoming_attention_anonymiser_endpoint.to_s
    end

    def anonymising?
      !anonymiser_endpoint.strip.empty?
    end

    def anonymiser_token
      ENV['INCOMING_ATTENTION_ANONYMISER_AUTH_TOKEN'].to_s
    end
  end
end
