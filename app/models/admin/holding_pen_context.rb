# Computes holding-pen routing guesses and rejection reason for a stored raw
# email so both RawEmailsController and the inline Today triage pane share it.
class Admin::HoldingPenContext
  attr_reader :raw_email

  def initialize(raw_email)
    @raw_email = raw_email
  end

  def in_holding_pen?
    raw_email.present? &&
      raw_email.kept? &&
      raw_email.incoming_message.info_request.holding_pen_request? &&
      !raw_email.empty_from_field?
  end

  def public_bodies
    @public_bodies ||= PublicBody.with_domain(raw_email.from_email_domain)
  end

  def guessed_info_requests
    @guessed_info_requests ||= begin
      guess_addresses = raw_email.addresses(include_invalid: true)
      by_email = InfoRequest.guess_by_incoming_email(guess_addresses)
      by_subject = InfoRequest.guess_by_incoming_subject(raw_email.subject)
      (by_email + by_subject).select(&:info_request).uniq(&:info_request)
    end
  end

  def rejected_reason
    @rejected_reason ||= begin
      event = InfoRequestEvent.find_by(
        incoming_message_id: raw_email.incoming_message.id
      )
      event&.params&.[](:rejected_reason) || 'unknown reason'
    end
  end
end
