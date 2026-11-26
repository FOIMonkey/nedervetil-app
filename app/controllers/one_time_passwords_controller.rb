# Password-bound enrolment, one-time code display and stepped-up removal.
class OneTimePasswordsController < ApplicationController
  include AuthenticationPages
  before_action :check_two_factor_config
  rate_limit to: 5, within: 5.minutes, only: [:start, :create, :destroy],
             name: 'otp-ip'
  rate_limit to: 5, within: 5.minutes, only: [:start, :create, :destroy],
             name: 'otp-account',
             by: -> {
               current_user&.id ||
                 AuthenticationEnrolment.pending(session)&.user_id ||
                 request.remote_ip
             }

  def show
    ask_to_login unless current_user
  end

  def new
    @enrolment = AuthenticationEnrolment.pending(session)
    return render(:new) if @enrolment
    return ask_to_login unless current_user
    return redirect_to(one_time_password_path) if current_user.totp?

    render :start
  end

  def start
    return ask_to_login unless current_user
    return head(:forbidden) unless current_user.active? && !current_user.totp?

    unless current_user.valid_password?(params[:password].to_s)
      flash.now[:error] = _('That password was not recognised.')
      return render :start, status: :unprocessable_content
    end

    AuthenticationEnrolment.start(session, current_user)
    redirect_to new_one_time_password_path
  end

  def create
    @enrolment = AuthenticationEnrolment.pending(session)
    return redirect_to(signin_path) unless @enrolment

    @codes = @enrolment.complete(params[:otp_code])
    unless @codes
      flash.now[:error] = _('Invalid or expired authentication code.')
      return render :new, status: :unprocessable_content
    end
    account = @enrolment.user
    session.delete(:authentication_enrolment)
    carry = session.to_hash.slice('authentication_return',
      'pending_request_draft', 'pending_draft_transfer')
    reset_session
    carry.each { |key, value| session[key] = value }
    Authentication::Session.establish(request, account, two_factor: true)
    @user = @current_user = account
    @continue_path = after_sign_in_path_for(account)
    render :codes
  end

  def destroy
    return ask_to_login unless current_user
    unless current_user.active? && !current_user.is_admin?
      return head(:forbidden)
    end

    removed = current_user.with_lock do
      unless current_user.valid_password?(params[:password].to_s) &&
             current_user.verify_second_factor!(params[:otp_code])
        next false
      end

      current_user.update!(otp_required_for_login: false, otp_secret: nil,
                           devise_otp_backup_codes: [], consumed_timestep: nil)
    end
    unless removed
      flash.now[:error] = _('The password or code was not recognised.')
      return render :show, status: :unprocessable_content
    end

    clear_session_credentials
    redirect_to signin_path,
      notice: _('Two factor authentication disabled. Please sign in.'),
      status: :see_other
  end

  private

  def check_two_factor_config
    return if AlaveteliConfiguration.enable_two_factor_auth

    raise ActiveRecord::RecordNotFound
  end
end
