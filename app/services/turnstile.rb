# Verifies Cloudflare Turnstile tokens (see doc/FORK.md).
# Fails closed outside development/test when unconfigured or unreachable;
# passes without keys in local environments.
module Turnstile
  SCRIPT_URL = 'https://challenges.cloudflare.com/turnstile/v0/api.js'.freeze
  VERIFY_URI =
    URI('https://challenges.cloudflare.com/turnstile/v0/siteverify')
  TOKEN_PARAM = 'cf-turnstile-response'.freeze
  # Cloudflare's own limit on a token's length.
  TOKEN_LIMIT = 2048
  TIMEOUT = 5
  # Config/service errors (:unavailable), distinct from user check failures.
  SITE_ERRORS = %w[missing-input-secret invalid-input-secret
                   internal-error].freeze
  NETWORK_ERRORS = [
    Net::OpenTimeout, Net::ReadTimeout, Net::WriteTimeout, SocketError,
    SystemCallError, OpenSSL::SSL::SSLError, IOError, Net::HTTPBadResponse,
    JSON::ParserError, Zlib::Error
  ].freeze

  Unreadable = Class.new(StandardError)

  module_function

  def site_key
    AlaveteliConfiguration.turnstile_site_key
  end

  def configured?
    site_key.present? &&
      AlaveteliConfiguration.turnstile_secret_key.present?
  end

  def hostname
    AlaveteliConfiguration.domain.split(':').first
  end

  # Returns :passed, :failed, or :unavailable (fail-closed outside local env).
  # Verifies both action and site hostname so tokens cannot be replayed across
  # forms or domains.
  def check(token, action:, remote_ip: nil)
    unless configured?
      return :passed if Rails.env.local?

      return unavailable('no keys')
    end
    return :failed if token.blank? || token.to_s.length > TOKEN_LIMIT

    answer(siteverify(token.to_s, remote_ip), action)
  rescue *NETWORK_ERRORS, Unreadable => e
    unavailable(e.class.name)
  end

  def answer(reply, action)
    codes = Array(reply['error-codes'])
    return unavailable(codes.join(' ')) if codes.intersect?(SITE_ERRORS)
    return :failed unless reply['success'] == true

    if reply['hostname'] == hostname && reply['action'] == action
      :passed
    else
      :failed
    end
  end
  private_class_method :answer

  def unavailable(cause)
    Rails.logger.warn("Turnstile can't answer: #{cause}")
    :unavailable
  end
  private_class_method :unavailable

  def siteverify(token, remote_ip)
    form = { secret: AlaveteliConfiguration.turnstile_secret_key,
             response: token }
    form[:remoteip] = remote_ip if remote_ip.present?
    response = Net::HTTP.start(VERIFY_URI.host, VERIFY_URI.port,
                               use_ssl: true,
                               open_timeout: TIMEOUT,
                               read_timeout: TIMEOUT,
                               write_timeout: TIMEOUT) do |http|
      http.post(VERIFY_URI.path, URI.encode_www_form(form),
                'Content-Type' => 'application/x-www-form-urlencoded')
    end
    raise Net::HTTPBadResponse, response.code unless
      response.is_a?(Net::HTTPSuccess)

    reply = JSON.parse(response.body)
    raise Unreadable unless reply.is_a?(Hash)

    reply
  end
  private_class_method :siteverify
end
