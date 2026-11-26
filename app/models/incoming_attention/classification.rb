module IncomingAttention
  # Status changes that the app, not a person, makes from replies' readings.
  module Classification
    # Prevents InfoRequest#set_described_state from marking replies reviewed.
    def self.automatically(&block)
      Current.set(automatic_classification: true, &block)
    end

    def self.automatic?
      Current.automatic_classification == true
    end

    # Clears awaiting_description when all unresolved replies are routine.
    def self.apply(request)
      return unless Config.enabled?

      request.with_lock do
        return unless request.awaiting_description?

        messages = Effective.unresolved(
          IncomingMessage.where(info_request_id: request.id)
        ).to_a
        unsettled = messages.any? do |message|
          Effective.notification_pending?(message) ||
            !Effective.routine?(message)
        end
        return if messages.empty? || unsettled
        return unless latest_reply_among?(request, messages)

        automatically { request.set_described_state(request.described_state) }
        Prediction.where(incoming_message_id: messages.map(&:id)).
          update_all(auto_classified: true)
      end
    end

    def self.latest_reply_among?(request, messages)
      latest = request.info_request_events.last
      latest&.event_type == 'response' &&
        messages.map(&:id).include?(latest.incoming_message_id)
    end
    private_class_method :latest_reply_among?
  end
end
