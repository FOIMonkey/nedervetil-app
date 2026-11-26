# Drops Set-Cookie when a session only holds STRIPPABLE_KEYS so read-only
# requests stay cookieless. If the browser already sent a session cookie (e.g.
# carrying a flash), explicitly deletes it so stale data is not replayed.
class StripEmptySessions
  ENV_SESSION_KEY = 'rack.session'.freeze
  HTTP_SET_COOKIE = 'set-cookie'.freeze
  STRIPPABLE_KEYS = %w(session_id _csrf_token locale).freeze

  def initialize(app, options = {})
    @app = app
    @options = options
  end

  def call(env)
    status, headers, body = @app.call(env)

    session_data = env[ENV_SESSION_KEY]
    session_cookie = headers[HTTP_SET_COOKIE]
    strippable = session_data && (session_data.keys - STRIPPABLE_KEYS).empty?

    if session_cookie && strippable
      # Preserve Rack's String-or-Array shape for set-cookie.
      others = Array(session_cookie).reject do |cookie|
        cookie.start_with?("#{@options[:key]}=")
      end
      others << delete_cookie if sent_cookie?(env)

      if others.empty?
        headers.delete(HTTP_SET_COOKIE)
      else
        headers[HTTP_SET_COOKIE] = others.one? ? others.first : others
      end
    end

    [status, headers, body]
  end

  private

  def sent_cookie?(env)
    env['HTTP_COOKIE'].to_s.match?(/(\A|;\s*)#{Regexp.escape(@options[:key])}=/)
  end

  def delete_cookie
    Rack::Utils.delete_set_cookie_header(
      @options[:key], path: @options[:path].presence || '/'
    )
  end
end
