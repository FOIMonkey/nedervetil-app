require 'net/http'
require 'uri'
require 'openssl'
require 'timeout'

module IncomingAttention
  # Shared HTTPS transport for reply classification and outcome assessment;
  # optionally routes through the anonymiser proxy (see doc/FORK.md).
  class Transport
    Error = Client::Error
    LOOPBACK = %w[localhost 127.0.0.1 ::1].freeze

    def post(body, path: '/v1/classify')
      uri = URI.parse(Config.endpoint)
      check_endpoint!(uri)

      uri.path = path
      uri = via_anonymiser(path) || uri
      extra = Config.anonymising? ? 10 : 0
      http = http_for(uri, path, extra)
      req = request_for(uri, body)
      Timeout.timeout((path == '/v1/classify' ? 25 : 35) + extra) do
        http.start do |connection|
          connection.request(req) do |res|
            return read_response(res)
          end
        end
      end
    rescue Error
      raise
    rescue URI::InvalidURIError, ArgumentError
      raise Error.new('worker_unconfigured', status: 'unavailable')
    rescue StandardError => e
      Rails.logger.warn("incoming_attention_transport_failed #{e.class}")
      raise Error.new('transport_failure',
                      status: 'unavailable', retryable: true)
    end

    private

    def check_endpoint!(uri)
      unless uri.is_a?(URI::HTTPS) && uri.host && !uri.userinfo &&
             uri.path == '/v1/classify' && !uri.query && !uri.fragment &&
             (32..512).cover?(Config.token.length)
        raise Error.new('worker_unconfigured', status: 'unavailable')
      end
    end

    # Anonymiser must be HTTPS, or loopback HTTP (near end of a secure tunnel).
    def via_anonymiser(path)
      return unless Config.anonymising?

      uri = URI.parse(Config.anonymiser_endpoint)
      secure = uri.is_a?(URI::HTTPS) ||
               (uri.is_a?(URI::HTTP) && LOOPBACK.include?(uri.host))
      unless secure && uri.host && !uri.userinfo && !uri.query &&
             !uri.fragment
        raise Error.new('anonymiser_unconfigured', status: 'unavailable')
      end

      uri.path = uri.path.delete_suffix('/') + path
      uri
    rescue URI::InvalidURIError
      raise Error.new('anonymiser_unconfigured', status: 'unavailable')
    end

    def http_for(uri, path, extra)
      http = Net::HTTP.new(uri.host, uri.port, nil)
      http.use_ssl = uri.is_a?(URI::HTTPS)
      http.verify_mode = OpenSSL::SSL::VERIFY_PEER
      http.open_timeout = 3
      http.read_timeout = (path == '/v1/classify' ? 20 : 30) + extra
      http.write_timeout = 3
      http
    end

    def request_for(uri, body)
      req = Net::HTTP::Post.new(uri.request_uri)
      req['Authorization'] = "Bearer #{Config.token}"
      # Only to the anonymiser: never to the worker.
      if Config.anonymising? && !Config.anonymiser_token.empty?
        req['X-Anonymiser-Token'] = Config.anonymiser_token
      end
      req['Content-Type'] = 'application/json'
      req['Accept'] = 'application/json'
      req.body = body
      req
    end

    def read_response(res)
      if [401, 403].include?(res.code.to_i)
        raise Error.new('worker_authentication', status: 'unavailable')
      end
      raise Error, 'worker_redirect' if (300..399).cover?(res.code.to_i)

      content_type = res['content-type'].to_s.split(';').first
      unless content_type == 'application/json'
        raise Error, 'worker_content_type'
      end

      bytes = +''
      res.read_body do |chunk|
        if bytes.bytesize + chunk.bytesize > Config::MAX_RESPONSE_BYTES
          raise Error, 'response_limit'
        end

        bytes << chunk
      end
      [res.code.to_i, bytes]
    end
  end
end
