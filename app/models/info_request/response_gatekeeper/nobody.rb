class InfoRequest
  module ResponseGatekeeper
    # Gatekeeper for nobody requests. Refuses all incoming email on requests
    # closed to new responses, by an administrator or by
    # InfoRequest.stop_new_responses_on_old_requests.
    class Nobody < Base
      def initialize(info_request)
        super
        @allow = false
        @reason = _('This request has been set by an administrator to ' \
                    '"allow new responses from nobody"')
      end
    end
  end
end
