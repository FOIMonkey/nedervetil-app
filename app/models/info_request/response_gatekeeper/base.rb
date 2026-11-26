class InfoRequest
  module ResponseGatekeeper
    # Default response gatekeeper for anybody requests and base class for
    # stricter gatekeepers. Allows all mail and delegates rejection_action to
    # the request's handle_rejected_responses setting.
    class Base
      attr_reader :info_request, :allow, :reason

      def initialize(info_request)
        @info_request = info_request
        @allow = true
        @reason = nil
      end

      def allow?(_mail)
        allow
      end

      def rejection_action
        info_request.handle_rejected_responses
      end
    end
  end
end
