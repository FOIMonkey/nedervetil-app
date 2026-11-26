# Authentication links, enrolment secrets and one-time recovery codes must not
# survive in Turbo's page snapshots or leave the page through a Referer.
module AuthenticationPages
  extend ActiveSupport::Concern

  included do
    before_action do
      keep_no_turbo_copy!
      set_no_crawl_headers
      SecureHeaders.use_secure_headers_override(request, :authentication)
    end
  end
end
