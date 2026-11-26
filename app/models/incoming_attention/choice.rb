module IncomingAttention
  # The requester's call on one reply's AI reading: it needs their attention,
  # or it is routine.
  module Choice
    VALUES = %w[attention routine].freeze

    # Returns the reply. The request and the reply are checked again under
    # the request's lock, against a transfer of either.
    def self.record!(request, message_id, value, ability:)
      message = nil
      request.with_lock do
        unless Config.enabled? && request.is_actual_owning_user?(ability.user)
          raise CanCan::AccessDenied
        end

        ability.authorize!(:read, request)
        message = request.incoming_messages.lock.find(message_id)
        message.info_request = request
        ability.authorize!(:read, message)
        row = Prediction.ensure_for(message)
        unless row && row.info_request_id == request.id
          raise CanCan::AccessDenied
        end

        row.update_columns(attention_override: value)
        if value == 'attention' && !Effective.reviewed?(message)
          request.update!(awaiting_description: true)
        end
      end
      Classification.apply(request) if value == 'routine'
      if value == 'attention'
        Outcome.queue(Prediction.for_message(message), message)
      end
      message
    end
  end
end
