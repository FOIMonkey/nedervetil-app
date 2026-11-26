class InfoRequest
  # Factory and namespace for handlers that dispose of incoming email refused
  # by a ResponseGatekeeper, selected by rejection action.
  module ResponseRejection
    class UnknownResponseRejectionError < ArgumentError; end

    SPECIALIZED_CLASSES = { 'bounce' => Bounce,
                            'holding_pen' => HoldingPen,
                            'blackhole' => Base,
                            'discard' => Base }.freeze

    def self.for(name, info_request, mail, **inbound_ids)
      SPECIALIZED_CLASSES.fetch(name).new(info_request, mail, **inbound_ids)
    rescue KeyError
      raise UnknownResponseRejectionError,
            "Unknown allow_new_responses_from '#{ name }'"
    end
  end
end
