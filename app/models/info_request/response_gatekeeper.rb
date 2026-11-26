class InfoRequest
  # Factory and namespace for gatekeepers that decide whether an incoming
  # email is accepted on an InfoRequest, selected by allow_new_responses_from.
  module ResponseGatekeeper
    class UnknownResponseGatekeeperError < ArgumentError; end

    SPECIALIZED_CLASSES = { 'nobody' => Nobody,
                            'anybody' => Base,
                            'authority_only' => AuthorityOnly }.freeze

    def self.for(name, info_request)
      SPECIALIZED_CLASSES.fetch(name).new(info_request)
    rescue KeyError
      raise UnknownResponseGatekeeperError,
            "Unknown allow_new_responses_from '#{ name }'"
    end
  end
end
