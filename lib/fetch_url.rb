require 'net/http'

# Raised by fetch_url! on failure; holds response for HTTP error statuses.
class FetchURLError < StandardError
  attr_reader :response

  def initialize(message, response: nil)
    super(message)
    @response = response
  end
end

# Fetches a URL body, logging a warning and returning "" on failure.
def fetch_url(url, timeout: 60)
  begin
    result = fetch_url!(url, timeout: timeout).strip
  rescue FetchURLError => exception
    e = FetchURLError.new(
      "Unable to open third-party URL #{url}: #{exception.message}",
      response: exception.response
    )
    e.set_backtrace(exception.backtrace)
    if !AlaveteliConfiguration.exception_notifications_from.blank? &&
       !AlaveteliConfiguration.exception_notifications_to.blank? &&
       defined?(request)
      ExceptionNotifier.notify_exception(e, env: request.env)
    end
    Rails.logger.warn(e.message)
    result = ""
  end
  result
end

def quietly_try_to_open(url, timeout = 60)
  warn %q([DEPRECATION] quietly_try_to_open will be removed in 0.48. It has
          been replaced by fetch_url).squish
  fetch_url(url, timeout: timeout)
end

# Fetches an HTTP(S) URL body, raising FetchURLError on failure.
# Rejects non-HTTP(S) schemes so URLs cannot read local files or run commands.
def fetch_url!(url, timeout: 60, redirects: 5)
  uri = URI.parse(url.to_s)
  unless uri.is_a?(URI::HTTP) && uri.host.present?
    raise FetchURLError, "Unsupported URL #{url}"
  end

  response = Net::HTTP.start(
    uri.hostname, uri.port,
    use_ssl: uri.is_a?(URI::HTTPS), read_timeout: timeout
  ) do |http|
    http.response_body_encoding = true
    http.request(Net::HTTP::Get.new(uri))
  end

  case response
  when Net::HTTPSuccess
    body = response.body.to_s
    # Match open-uri, which reads text without a charset as UTF-8
    if body.encoding == Encoding::BINARY && response.main_type == 'text'
      body.force_encoding(Encoding::UTF_8)
    end
    body
  when Net::HTTPRedirection
    fetch_url_follow_redirect(uri, response, url,
                              timeout: timeout, redirects: redirects)
  else
    raise FetchURLError.new(
      "#{response.code} #{response.message}", response: response
    )
  end

rescue URI::Error, SocketError, SystemCallError, IOError, Timeout::Error,
       OpenSSL::SSL::SSLError, Net::ProtocolError, Net::HTTPBadResponse => e
  raise FetchURLError, e.message
end

def fetch_url_follow_redirect(uri, response, url, timeout:, redirects:)
  raise FetchURLError, "Too many redirects for #{url}" if redirects.zero?

  location = response['location']
  if location.blank?
    raise FetchURLError.new(
      "#{response.code} #{response.message}", response: response
    )
  end

  target = URI.join(uri, location)
  if uri.is_a?(URI::HTTPS) && !target.is_a?(URI::HTTPS)
    raise FetchURLError, "Refused redirect from HTTPS to #{target}"
  end

  fetch_url!(target, timeout: timeout, redirects: redirects - 1)
end
