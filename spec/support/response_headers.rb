module ResponseHeaders
  PER_RESPONSE = %w[x-request-id x-runtime].freeze

  def sent_headers
    response.headers.to_h.except(*PER_RESPONSE)
  end

  # Rack returns a String for one Set-Cookie header and an Array for several.
  def cookies_set
    Array(response.headers['set-cookie'])
  end

  def cookie_attributes(cookie)
    cookie.split('; ').drop(1).map(&:downcase)
  end

  def page_policy
    response.headers['content-security-policy'].
      sub(/'nonce-[^']+'/, "'nonce'")
  end
end

RSpec.configure do |config|
  config.include ResponseHeaders, type: :request
end
