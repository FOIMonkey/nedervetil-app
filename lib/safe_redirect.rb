require 'uri'

# Parses a redirect target and rebuilds a local absolute path without scheme
# or host, preventing open redirects.
class SafeRedirect
  attr_reader :uri

  def initialize(redirect_parameter)
    @uri = URI.parse(redirect_parameter)
  end

  def path(opts = {})
    query = opts[:query]
    URI::Generic.build(path: absolute_path, query: query,
                       fragment: uri.fragment).to_s
  end

  private

  # A path with no leading slash is relative to the current page, which
  # Rails refuses to redirect to.
  def absolute_path
    path = uri.path
    return path if path.blank? || path.start_with?('/')

    "/#{path}"
  end
end
