# Automatic InfoRequest status transitions on outgoing delivery results.
# Runs under the request's row lock (shared with reply receipt) and never
# consumes an unread reply (see doc/FORK.md).
module OutgoingMessage::DeliveryTransitions
  extend ActiveSupport::Concern

  SENT_EVENTS = %w[followup_sent followup_resent].freeze

  private

  def record_failure_status
    request = info_request
    request.with_lock do
      return if defined?(Deadlines::Closure) &&
                Deadlines::Closure.unread_replies?(request)

      automatic { request.set_described_state('error_message') }
    end
  end

  # Guards with awaiting_description? instead of unread_replies? so an
  # auto-read reply being answered doesn't block clearing waiting_clarification.
  def record_followup_status
    request = info_request
    request.with_lock do
      return if request.awaiting_description?

      automatic do
        if request.described_state == 'waiting_clarification'
          request.set_described_state('waiting_response')
        end
        if what_doing == 'internal_review'
          request.set_described_state('internal_review')
        end
      end
    end
  end

  # Restores the pre-failure state when a resent follow-up succeeds, since
  # set_info_request_described_state only advances clarification/review states.
  def restore_status_after_resend
    unless message_type == 'followup' && status == 'sent' &&
           what_doing != 'internal_review'
      return
    end

    request = info_request
    # Keep checks, status write and due-date update inside the row lock.
    request.with_lock do
      return unless request.described_state == 'error_message'
      return if defined?(Deadlines::Closure) &&
                Deadlines::Closure.unread_replies?(request)

      events = request.info_request_events.order(:id).to_a
      sent = last_send(events) or return

      # Ignore failures from other messages or already followed by a send.
      failure = explaining_failure(events, sent) or return

      before = state_before(events, failure)

      automatic do
        if before == 'waiting_clarification'
          request.set_described_state('waiting_response')
          request.update_due_dates(sent)
        else
          request.set_described_state(before)
        end
      end
    end
  end

  def last_send(events)
    sent = events.last
    unless sent&.outgoing_message_id == id &&
           SENT_EVENTS.include?(sent.event_type)
      return
    end

    sent
  end

  def explaining_failure(events, sent)
    failure = events.reverse.
      find { |event| event.event_type == 'send_error' } or return
    return unless failure.outgoing_message_id == id
    return if events.any? { |event|
      event.id > failure.id && event.id < sent.id &&
      event.outgoing_message_id == id &&
      SENT_EVENTS.include?(event.event_type)
    }

    failure
  end

  def state_before(events, failure)
    events.select { |event| event.id < failure.id }.reverse.
      filter_map(&:described_state).
      find { |state| state != 'error_message' } || 'waiting_response'
  end

  def automatic(&block)
    if defined?(IncomingAttention::Classification)
      IncomingAttention::Classification.automatically(&block)
    else
      yield
    end
  end
end
