# Establish Warden state only after password, factor and site-policy checks.
class Users::SessionsController < Devise::SessionsController
  include AuthenticationPages
  include UserSpamCheck
  skip_before_action :require_no_authentication
  rate_limit to: 10, within: 1.minute, only: :create, name: 'ip'
  rate_limit to: 5, within: 1.minute, only: :create, name: 'email',
             by: -> { credentials['email'].to_s.strip.downcase }
  layout :sign_page_layout
  self.framed_by_sign_in_dialog = true

  def new
    @user_signin = User.new
  end

  def create
    data = credentials
    user = User.find_user_by_email(data['email'])
    request.env['warden'].logout(:user)
    # Discard any unfinished 2FA enrolment from the previous signed-in user.
    session.delete(:authentication_enrolment)
    @user = @current_user = @current_ability = nil
    password_valid = user&.valid_password?(data['password'].to_s)
    unless password_valid && user.active_for_authentication? &&
           !blocked_spam?(user)
      User.new.password = data['password'].to_s unless user
      return failed_sign_in
    end

    PendingRequestDraft.for_browser(session)&.bind_to(user)
    if user.requires_two_factor_enrolment?
      remember_destination(user)
      AuthenticationEnrolment.start(session, user)
      return redirect_to new_one_time_password_path
    end

    # These are the only credential strategies. store:false leaves Warden
    # empty until all policy checks and required factors have succeeded.
    request.parameters['user'] = data.with_indifferent_access
    result = request.env['warden'].authenticate(
      :two_factor_backupable, :two_factor_authenticatable,
      scope: :user, store: false
    )
    return failed_sign_in unless result && result.id == user.id

    remaining = backup_codes_remaining(result)
    remember_destination(result)
    complete_authentication(result, two_factor: result.totp?,
                                    backup_codes_remaining: remaining)
  end

  def confirm_destroy
    render 'users/sessions/sign_out'
  end

  def destroy
    current_user&.revoke_authentication!
    clear_session_credentials
    redirect_to frontpage_path, status: :see_other
  end

  private

  def credentials
    value = params[:user] || params[:user_signin]
    return {} unless value.is_a?(ActionController::Parameters)

    value.permit(:email, :password, :otp_attempt).to_h
  end

  def backup_codes_remaining(result)
    strategy = request.env['warden'].winning_strategy
    used_recovery_code = strategy.is_a?(Devise::Strategies::TwoFactorBackupable)
    remaining = result.otp_backup_codes.size if used_recovery_code
    remaining
  end

  def remember_destination(user)
    return unless params.key?(:r)

    AuthenticationReturn.remember(session, params[:r], user: user)
  end

  def blocked_spam?(user)
    spam_user?(user) && handle_spam_user(user, 'signin',
      block: AlaveteliConfiguration.block_spam_signins)
  end

  def failed_sign_in
    request.env['warden'].logout(:user)
    @user_signin = User.new(email: credentials['email'])
    @user_signin.errors.add(:base,
      _('The email, password or authentication code was not recognised.'))
    render :new, status: :unprocessable_content
  end
end
