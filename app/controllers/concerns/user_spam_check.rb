# Spam scoring for the account actions: sign-up, sign-in and email change
# (UserSpamScorer.for_accounts).
module UserSpamCheck
  extend ActiveSupport::Concern

  private

  def spam_user?(user)
    # The role, not a permission: an admin account isn't a spam suspect.
    return false if user.active_admin? || user.confirmed_not_spam?

    user_with_request = User::WithRequest.new(user, request)
    UserSpamScorer.for_accounts.spam?(user_with_request)
  end

  # Handles a suspected spammer: calls refusal block when block: true, else
  # notifies admins. Returns `block` so callers can `... && return`.
  def handle_spam_user(user, action, block:, &refusal)
    msg = "Attempted #{action} from suspected spammer, " \
          "email: #{user.email}, " \
          "name: '#{user.name}'"

    if block
      logger.info(msg)
      refusal&.call
    elsif send_exception_notifications?
      ExceptionNotifier.notify_exception(Exception.new(msg), env: request.env)
    end
    block
  end
end
