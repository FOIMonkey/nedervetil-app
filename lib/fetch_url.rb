require 'ipaddr'
require 'net/http'
require 'socket'

ALLOWED_FETCH_PORTS = [80, 443].freeze
MAX_FETCH_BYTES = 2 * 1024 * 1024
PRIVATE_FETCH_RANGES = [
  IPAddr.new('0.0.0.0/8'),
  IPAddr.new('10.0.0.0/8'),
  IPAddr.new('100.64.0.0/10'),
  IPAddr.new('127.0.0.0/8'),
  IPAddr.new('169.254.0.0/16'),
  IPAddr.new('172.16.0.0/12'),
  IPAddr.new('192.0.0.0/24'),
  IPAddr.new('192.168.0.0/16'),
  IPAddr.new('198.18.0.0/15'),
  IPAddr.new('224.0.0.0/4'),
  IPAddr.new('240.0.0.0/4'),
  IPAddr.new('::/128'),
  IPAddr.new('::1/128'),
  IPAddr.new('fc00::/7'),
  IPAddr.new('fe80::/10'),
  IPAddr.new('ff00::/8')
].freeze

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
# Rejects non-HTTP(S) schemes, non-standard ports, private/loopback IPs,
# and bodies exceeding MAX_FETCH_BYTES.
def fetch_url!(url, timeout: 60, redirects: 5)
  uri = parse_fetch_uri(url)
  body, response = perform_fetch_request(uri, timeout)

  case response
  when Net::HTTPSuccess
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

def parse_fetch_uri(url)
  uri = URI.parse(url.to_s)
  unless uri.is_a?(URI::HTTP) && uri.host.present?
    raise FetchURLError, "Unsupported URL #{url}"
  end
  unless ALLOWED_FETCH_PORTS.include?(uri.port)
    raise FetchURLError, "Unsupported port #{uri.port} for #{url}"
  end

  uri
end

def perform_fetch_request(uri, timeout)
  pinned_ip = resolve_fetch_ip(uri.hostname)
  http_opts = { use_ssl: uri.is_a?(URI::HTTPS), read_timeout: timeout,
                open_timeout: [timeout, 15].min }
  http_opts[:ipaddr] = pinned_ip if pinned_ip

  body = nil
  response = nil
  Net::HTTP.start(uri.hostname, uri.port, **http_opts) do |http|
    http.request(Net::HTTP::Get.new(uri)) do |res|
      response = res
      body = read_fetch_body(res) if res.is_a?(Net::HTTPSuccess)
    end
  end
  [body, response]
end

def read_fetch_body(res)
  buf = +''.b
  res.read_body do |chunk|
    buf << chunk.b
    if buf.bytesize > MAX_FETCH_BYTES
      raise FetchURLError, "Response exceeded #{MAX_FETCH_BYTES} bytes"
    end
  end
  encode_fetch_body(buf, res)
end

def encode_fetch_body(buf, response)
  charset = response.type_params['charset']
  if charset
    buf.force_encoding(Encoding.find(charset))
  elsif response.main_type == 'text'
    buf.force_encoding(Encoding::UTF_8)
  end
  buf
rescue ArgumentError
  buf
end

def validate_fetch_ip!(ip_str)
  addr = IPAddr.new(ip_str)
  addr = addr.native if addr.ipv4_mapped?
  if addr.loopback? || addr.private? || addr.link_local? ||
     PRIVATE_FETCH_RANGES.any? { |range| range.include?(addr) }
    raise FetchURLError, "Refused non-public address #{ip_str}"
  end
end

def resolve_fetch_ip(hostname)
  host = hostname.to_s.downcase.chomp('.')
  if host == 'localhost' || host.end_with?('.localhost', '.internal', '.local')
    raise FetchURLError, "Refused internal host #{hostname}"
  end

  begin
    validate_fetch_ip!(host)
    return host
  rescue IPAddr::InvalidAddressError
    nil
  end

  return nil if defined?(WebMock) && !WebMock.net_connect_allowed?

  addrs = Addrinfo.getaddrinfo(hostname, nil, nil, :STREAM).
          map(&:ip_address).uniq
  raise FetchURLError, "Could not resolve #{hostname}" if addrs.empty?

  addrs.each { |ip| validate_fetch_ip!(ip) }
  addrs.first
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
