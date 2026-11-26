# Recovery changes the password and then requires complete sign-in.
class Users::PasswordsController < Devise::PasswordsController
  include AuthenticationPages
  skip_before_action :require_no_authentication
  rate_limit to: 10, within: 15.minutes, only: [:create, :update],
             name: 'reset-ip'
  rate_limit to: 3, within: 15.minutes, only: :create, name: 'reset-email',
             by: -> {
               params.dig(:password_change_user, :email).to_s.strip.downcase
             }
  # Keyed on the token digest so the cache never stores a usable reset link.
  rate_limit to: 5, within: 15.minutes, only: :update, name: 'reset-token',
             by: -> { reset_digest(params[:id].to_s) }

  def new
    render 'users/passwords/new'
  end

  def create
    address = params.dig(:password_change_user, :email).to_s
    user = User.not_closed.find_user_by_email(address)
    user&.send_reset_password_instructions
    render 'users/confirmations/check_email'
  end

  def edit
    token = params[:id].to_s
    digest = reset_digest(token)
    account = User.find_by(reset_password_token: digest) if token.present?
    @reset_token = params[:id]
    @totp_required = resettable?(account, digest) && account.totp?
    render 'users/passwords/edit'
  end

  def update
    token = params[:id].to_s
    digest = reset_digest(token)
    account = User.find_by(reset_password_token: digest) if token.present?
    data = reset_fields
    unless apply_reset(account, digest, data)
      @reset_token = token
      @password_change_user = account
      @totp_required = resettable?(account, digest) && account.totp?
      return render 'users/passwords/edit', status: :unprocessable_content
    end
    sign_out_keeping_letter
    redirect_to signin_path, notice: changed_notice(account),
                             status: :see_other
  rescue ActionController::ParameterMissing
    head :unprocessable_content
  end

  private

  def apply_reset(account, digest, data)
    account&.with_lock do
      next false unless resettable?(account, digest)

      reset_under_savepoint(account, data)
    end
  end

  # Rolled back if the new password is invalid, so a typo does not use up a
  # recovery code or an authenticator code.
  def reset_under_savepoint(account, data)
    changed = false
    User.transaction(requires_new: true) do
      if second_factor_passed?(account, data[:otp_attempt])
        changed = reset_password_saved?(account, data)
        raise ActiveRecord::Rollback unless changed
      end
    end
    changed
  end

  def second_factor_passed?(account, code)
    return true unless account.totp?
    return true if account.verify_second_factor!(code)

    account.errors.add(:base, _('Invalid or expired authentication code.'))
    false
  end

  def reset_password_saved?(account, data)
    return false unless account.reset_password(
      data[:password], data[:password_confirmation]
    )

    confirm_on_reset!(account)
    true
  end

  # Resetting proves mailbox ownership; skip_confirmation! avoids Devise's
  # confirmation-window expiry check.
  def confirm_on_reset!(account)
    return if account.confirmed?

    account.skip_confirmation!
    account.save!
  end

  def changed_notice(account)
    if account.totp?
      _('Password changed. Sign in with your new password and your next ' \
        'authenticator code or another recovery code.')
    else
      _('Password changed. Please sign in.')
    end
  end

  def reset_digest(token)
    Devise.token_generator.digest(User, :reset_password_token, token)
  end

  def resettable?(account, digest)
    account.present? && !account.closed? &&
      account.reset_password_token == digest &&
      account.reset_password_period_valid?
  end

  def reset_fields
    fields = params.require(:password_change_user)
    unless fields.is_a?(ActionController::Parameters)
      raise ActionController::ParameterMissing, :password_change_user
    end

    fields.permit(:password, :password_confirmation, :otp_attempt)
  end

  def sign_out_keeping_letter
    letter = session.to_hash.slice('pending_request_draft',
      'pending_draft_transfer')
    clear_session_credentials
    letter.each { |key, value| session[key] = value }
  end

  # Public reset URLs pass the token in :id; override Devise's default
  # query-param check so valid links aren't redirected to sign-in.
  def assert_reset_token_passed
    head :not_found if params[:id].blank?
  end
end
