# The person check (Turnstile) for a controller whose form shows
# ApplicationHelper#turnstile_box with the same action.
module TurnstileCheck
  private

  # Returns an error message on failure/unavailability, or nil on pass.
  # `action` binds the Turnstile token to this specific form.
  def turnstile_refusal(action)
    case Turnstile.check(params[Turnstile::TOKEN_PARAM], action: action,
                                                         remote_ip: user_ip)
    when :passed
      nil
    when :failed
      _("We couldn't confirm that you're a person. Please try again.")
    else
      notify_turnstile_unavailable(action)
      _("Sorry, we can't check this form at the moment. " \
        'Please try again later.')
    end
  end

  # Log every failure, but rate-limit admin exception emails to once/hour/form.
  def notify_turnstile_unavailable(action)
    message = "Turnstile couldn't check the #{action} form"
    logger.error(message)
    return unless send_exception_notifications?
    return unless Rails.cache.write("turnstile-unavailable-#{action}", true,
                                    unless_exist: true, expires_in: 1.hour)

    ExceptionNotifier.notify_exception(Exception.new(message),
                                       env: request.env)
  end
end
