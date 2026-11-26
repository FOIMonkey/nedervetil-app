module Authentication
  # Devise's default timeout response redirects to the attempted URL and
  # stores its unfiltered parameters. Every failure uses our bounded return.
  class FailureApp < Devise::FailureApp
    protected

    def redirect_url
      path = attempted_path
      if request.path == '/pro/info_requests' &&
         request.params['draft_id'].to_s.match?(/\A[1-9]\d{0,18}\z/)
        path = "/pro/info_requests/new?draft_id=#{request.params['draft_id']}"
      end
      destination = Authentication::ReturnPath.normalize(path)
      return scope_url if destination == Authentication::ReturnPath::DEFAULT

      uri = URI.parse(scope_url)
      uri.query = { r: destination }.to_query
      uri.to_s
    end

    def store_location!
      # The normalized destination travels in the redirect/form, not storage.
    end
  end
end
