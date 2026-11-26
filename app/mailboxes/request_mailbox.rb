# Routes inbound mail to matching/guessed InfoRequests or the holding pen,
# dropping SpamAddress matches. Re-queues refused mail reads up to
# ROUTE_AGAIN_FOR (already_received? deduplicates; see doc/FORK.md).
class RequestMailbox < ApplicationMailbox
  include ConfigHelper

  ROUTE_AGAIN_EVERY = 10.minutes
  ROUTE_AGAIN_FOR = 12.hours

  rescue_from MailHandler::ReadRefused, with: :route_again_later

  def process
    return if spam?

    if exact_info_requests.count > 0
      # Go through each exact info request and deliver the email
      exact_info_requests.each do |info_request|
        info_request.receive(mail, **args)
      end

    elsif guessed_info_requests.count == 1
      # If there one guess automatically redeliver the email to that and log it
      # as an event
      info_request = guessed_info_requests.first
      info_request.log_event(
        'redeliver_incoming',
        editor: 'automatic',
        destination_request: info_request
      )
      info_request.receive(mail, **args)

    else
      # Otherwise we send the mail to the holding pen
      send_to_holding_pen
    end
  end

  private

  # Enqueue before marking pending so a failed enqueue leaves the email failed
  # rather than stranded in pending.
  def route_again_later(error)
    return give_up_routing(error) if inbound_email.created_at <
                                     ROUTE_AGAIN_FOR.ago

    ActionMailbox::RoutingJob.set(wait: ROUTE_AGAIN_EVERY).
      perform_later(inbound_email) or raise error
    inbound_email.pending!
  end

  def give_up_routing(error)
    logger.warn("InboundEmail #{inbound_email.id}: left as failed after " \
                "#{ROUTE_AGAIN_FOR.inspect} (#{error.message})")
    return unless send_exception_notifications?

    ExceptionNotifier.notify_exception(
      error, data: { inbound_email_id: inbound_email.id }
    )
  end

  def addresses
    @addresses ||= MailHandler.get_all_addresses(mail)
  end

  def spam?
    SpamAddress.spam?(addresses)
  end

  def exact_info_requests
    @exact_info_requests ||= InfoRequest.matching_incoming_email(addresses)
  end

  def guessed_info_requests
    @guessed_info_requests ||= Guess.guessed_info_requests(addresses)
  end

  def send_to_holding_pen
    reason = _("Could not identify the request from the email address")
    InfoRequest.holding_pen_request.receive(
      mail, **args(rejected_reason: reason)
    )
  end

  def args(**extra_args)
    extra_args.merge(
      message_id: inbound_email.message_id,
      message_checksum: inbound_email.message_checksum
    )
  end
end
