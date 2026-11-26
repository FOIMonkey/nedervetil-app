# Validates and normalises linkable http/https URLs with a non-empty host,
# rejecting javascript:, data:, relative paths and malformed values.
module HttpUrl
  module_function

  def parse(value)
    text = value.to_s.strip
    return if text.empty?

    uri = URI.parse(text)
    text if uri.is_a?(URI::HTTP) && uri.host.present?
  rescue URI::InvalidURIError
    nil
  end

  def with_default_scheme(value)
    text = value.to_s.strip
    return if text.empty?

    parse(text) || (parse("https://#{text}") if bare_host?(text))
  end

  # URI.parse treats "host:port" as scheme "host", so match bare hosts first.
  def bare_host?(text)
    text.match?(%r{\A[a-z0-9-]+(\.[a-z0-9-]+)+(:\d+)?([/?#]|\z)}i)
  end
end
