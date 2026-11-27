require 'json'
require 'net/http'
require 'openssl'
require 'timeout'
require 'uri'

module Disclosures
  # Calls the site's self-hosted PII service (Presidio or badger/v1) over HTTPS
  # or loopback to check hidden content for personal data. Fails closed to
  # :unavailable; not subject to requester AI opt-out. See doc/FORK.md.
  module PiiCheck
    MODES = %w[off presidio ai].freeze
    CONTRACT = 'badger/v1'.freeze
    MAX_BYTES = 100_000
    # Overlap between split chunks so a name at a boundary stays whole.
    OVERLAP = 500
    MAX_CALLS = 10
    MAX_RESPONSE = 1.megabyte
    SCORE = 0.6
    DEFAULT_ENTITIES = %w[PERSON EMAIL_ADDRESS].freeze
    LOOPBACK = %w[localhost 127.0.0.1 ::1].freeze

    Unavailable = Class.new(StandardError)

    module_function

    def mode
      value = AlaveteliConfiguration.disclosures_pii_check.to_s
      MODES.include?(value) ? value : 'off'
    end

    def enabled?
      mode != 'off'
    end

    # Returns :personal, :clear, or :unavailable (also when off: fail closed).
    def call(texts)
      return :unavailable unless enabled?

      chunks = chunk(Array(texts).join("\n"))
      return :clear if chunks.empty?
      return :unavailable if chunks.size > MAX_CALLS

      chunks.any? { |text| personal?(text) } ? :personal : :clear
    rescue Unavailable, Timeout::Error, SocketError, SystemCallError,
           OpenSSL::SSL::SSLError, JSON::ParserError, Net::HTTPError,
           EOFError => e
      Rails.logger.warn("Disclosures::PiiCheck unavailable: #{e.class}")
      :unavailable
    end

    def entities
      Array(AlaveteliConfiguration.disclosures_pii_check_entities).
        map(&:to_s).reject(&:empty?).presence || DEFAULT_ENTITIES
    end

    def chunk(text)
      text = text.strip
      return [] if text.empty?

      chunks = [+'']
      text.each_line.flat_map { |line| pieces(line) }.each do |piece|
        chunks << +'' if chunks.last.bytesize + piece.bytesize > MAX_BYTES
        chunks.last << piece
      end
      chunks.reject(&:empty?)
    end

    # Splits oversize lines into overlapping char chunks (<= 4 bytes/char).
    def pieces(line)
      return [line] if line.bytesize <= MAX_BYTES

      size = MAX_BYTES / 4
      (0...line.length).step(size - OVERLAP).map { |at| line[at, size] }
    end

    def personal?(text)
      if mode == 'presidio'
        found = post('/analyze', text: text, language: 'en',
                                 entities: entities, score_threshold: SCORE)
        raise Unavailable, 'not a list' unless found.is_a?(Array)

        found.any? do |item|
          entities.include?(item['entity_type']) && item['score'].to_f >= SCORE
        end
      else
        found = post(nil, contract_version: CONTRACT, text: text,
                          language: 'en')
        findings = found.is_a?(Hash) && found['findings']
        raise Unavailable, 'no findings' unless findings.is_a?(Array)

        findings.any? do |item|
          entities.include?(item['type']) && item['score'].to_f >= SCORE
        end
      end
    end

    def post(path, body)
      uri = endpoint
      uri.path = uri.path.delete_suffix('/') + path if path
      http = Net::HTTP.new(uri.host, uri.port, nil)
      http.use_ssl = uri.is_a?(URI::HTTPS)
      http.verify_mode = OpenSSL::SSL::VERIFY_PEER
      http.open_timeout = 3
      http.read_timeout = 20
      http.write_timeout = 5
      request = build_request(uri, body)
      Timeout.timeout(30) { JSON.parse(read_response(http, request)) }
    end

    def build_request(uri, body)
      request = Net::HTTP::Post.new(uri.request_uri)
      request['Content-Type'] = 'application/json'
      request['Accept'] = 'application/json'
      token = ENV['DISCLOSURES_PII_CHECK_AUTH_TOKEN'].to_s
      request['Authorization'] = "Bearer #{token}" unless token.empty?
      request.body = JSON.generate(body)
      request
    end

    def read_response(http, request)
      buf = +''.b
      http.start do |conn|
        conn.request(request) do |response|
          raise Unavailable, response.code unless response.code.to_i == 200

          length = response['Content-Length']&.to_i
          raise Unavailable, 'too large' if length && length > MAX_RESPONSE

          response.read_body do |chunk|
            buf << chunk.b
            raise Unavailable, 'too large' if buf.bytesize > MAX_RESPONSE
          end
        end
      end
      buf.force_encoding(Encoding::UTF_8)
    end

    def endpoint
      uri = URI.parse(
        AlaveteliConfiguration.disclosures_pii_check_endpoint.to_s
      )
      secure = uri.is_a?(URI::HTTPS) ||
               (uri.is_a?(URI::HTTP) && LOOPBACK.include?(uri.host))
      raise Unavailable, 'endpoint' unless secure && uri.host && !uri.userinfo

      uri
    rescue URI::InvalidURIError
      raise Unavailable, 'endpoint'
    end
  end
end
