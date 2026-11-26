module IncomingAttention
  # The requester has seen these routine replies: replies to one request, or
  # to requests in its batch.
  module Dismissal
    # The replies are not all there, or not all in the request or its batch.
    Invalid = Class.new(StandardError)

    # Locks requests and messages in id order and authorizes all before writing
    # any marker, preventing partial dismissal or TOCTOU via reassignment.
    # Reloads request under lock for the caller.
    def self.record!(request, message_ids, ability:)
      request_ids = IncomingMessage.where(id: message_ids).
        pluck(:info_request_id)
      raise Invalid unless request_ids.size == message_ids.size

      InfoRequest.transaction do
        requests = InfoRequest.where(id: request_ids + [request.id]).
          order(:id).lock.index_by(&:id)
        request.reload
        messages = IncomingMessage.where(id: message_ids).order(:id).lock.to_a
        same_request_or_batch =
          same_request_or_batch?(messages, requests, request)
        unless messages.size == message_ids.size && same_request_or_batch
          raise Invalid
        end

        authorize_all!(requests, messages, ability)
        mark_reviewed(messages, message_ids)
      end
    end

    def self.same_request_or_batch?(messages, requests, request)
      batch_id = request.info_request_batch_id
      messages.all? do |message|
        target = requests[message.info_request_id]
        target && (target.id == request.id ||
                   (batch_id.present? &&
                    target.info_request_batch_id == batch_id))
      end
    end
    private_class_method :same_request_or_batch?

    def self.authorize_all!(requests, messages, ability)
      requests.each_value do |target|
        unless Config.enabled? && target.is_actual_owning_user?(ability.user)
          raise CanCan::AccessDenied
        end

        ability.authorize!(:read, target)
      end
      messages.each do |message|
        message.info_request = requests.fetch(message.info_request_id)
        ability.authorize!(:read, message)
      end
    end
    private_class_method :authorize_all!

    def self.mark_reviewed(messages, message_ids)
      rows = Prediction.where(incoming_message_id: message_ids).
        order(:id).lock.index_by(&:incoming_message_id)
      messages.each do |message|
        row = rows[message.id]
        next unless row && row.info_request_id == message.info_request_id &&
                    Effective.routine?(message)

        row.update_columns(human_reviewed_at: Time.current)
      end
    end
    private_class_method :mark_reviewed
  end
end
