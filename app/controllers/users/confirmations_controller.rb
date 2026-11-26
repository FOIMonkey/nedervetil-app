# Mailbox confirmation grants no authenticated session or request send.
class Users::ConfirmationsController < Devise::ConfirmationsController
  include AuthenticationPages
  rate_limit to: 10, within: 15.minutes, only: [:create, :update],
             name: 'confirmation-ip'
  rate_limit to: 3, within: 15.minutes, only: :create,
             name: 'confirmation-email',
             by: -> {
               params.dig(:user, :email).to_s.strip.downcase
             }

  def new
    render 'users/confirmations/resend'
  end

  def show
    @confirmation = account_for_token
    return render('user/bad_token', status: :not_found) unless @confirmation

    @request_saved = draft_saved?(@confirmation)
    render 'users/confirmations/new'
  end

  def update
    account = account_for_token
    return render('user/bad_token', status: :not_found) unless account

    data = chosen_password
    confirmed = account.with_lock do
      unless account.confirmation_token == confirmation_token &&
             !account.closed?
        next false
      end
      # Idempotent on double submit after the first request confirmed it.
      next true if account.confirmed?

      # Password is chosen here by whoever controls the mailbox.
      account.password = data[:password].to_s
      account.password_confirmation = data[:password_confirmation].to_s
      next true if account.confirm(ensure_valid: true)

      account.errors.any? ? :invalid : false
    end
    if confirmed == :invalid
      @confirmation = account
      @request_saved = draft_saved?(account)
      return render 'users/confirmations/new', status: :unprocessable_content
    end
    return render('user/bad_token', status: :not_found) unless confirmed

    PendingRequestDraft.accept_transfer(session, params[:draft_claim],
      account) if params[:draft_claim].present?
    # Grants no session, draft claim, or password-reset privilege.
    redirect_to signin_path, notice: _('Email confirmed. Please sign in.'),
                             status: :see_other
  end

  def create
    address = params.dig(:user, :email).to_s
    account = User.not_closed.find_user_by_email(address)
    if account && !account.confirmed?
      pending = PendingRequestDraft.for_browser(session)
      if pending&.intended_user_id == account.id
        account.draft_claim_for_confirmation = pending.transfer_token
      end
      account.send_confirmation_while_pending
    end
    render 'users/confirmations/check_email'
  end

  private

  def chosen_password
    fields = params[:confirm_user]
    return {} unless fields.is_a?(ActionController::Parameters)

    fields.permit(:password, :password_confirmation)
  end

  # Confirmation links outlive pending drafts (1 day vs 30 min).
  def draft_saved?(account)
    PendingRequestDraft.for_transfer(params[:draft_claim].to_s, account).
      present?
  end

  def confirmation_token
    params[:email_token].to_s
  end

  def account_for_token
    return if params[:email_token].blank?

    account = User.find_by(confirmation_token: confirmation_token)
    account if account && !account.closed? && account.confirmation_sent_at &&
               account.confirmation_sent_at > 1.day.ago && !account.confirmed?
  end
end
