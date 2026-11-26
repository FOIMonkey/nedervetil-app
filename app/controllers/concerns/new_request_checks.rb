# Anti-spam and first-request Turnstile checks run before sending a single
# request (see doc/FORK.md).
module NewRequestChecks
  extend ActiveSupport::Concern

  include TurnstileCheck

  included do
    helper_method :new_request_turnstile?
  end

  private

  def new_request_turnstile?
    current_user.limited_profile?
  end

  # nil when the request may be sent, otherwise the message to show.
  def new_request_refusal(info_request)
    return if current_user.confirmed_not_spam?

    spam_subject_refusal(info_request) || person_check_refusal
  end

  def spam_subject_refusal(info_request)
    subject = info_request.outgoing_messages.first.subject
    return unless AlaveteliSpamTermChecker.new.spam?(
      AsciiText.transliterate(subject, lookalikes: true)
    )

    notify_admins("Spam request from user #{current_user.id}")
    unable_to_send if AlaveteliConfiguration.block_spam_requests
  end

  def person_check_refusal
    return unless new_request_turnstile?

    turnstile_refusal('first_request')
  end

  def unable_to_send
    _("Sorry, we're currently unable to send your request. " \
      'Please try again later.')
  end

  def notify_admins(message)
    return unless send_exception_notifications?

    ExceptionNotifier.notify_exception(Exception.new(message),
                                       env: request.env)
  end
end
