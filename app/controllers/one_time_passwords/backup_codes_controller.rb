# Replace recovery codes only after a fresh password and second factor.
class OneTimePasswords::BackupCodesController < ApplicationController
  include AuthenticationPages
  before_action :require_account
  rate_limit to: 5, within: 5.minutes, only: :create, name: 'backup-codes'
  rate_limit to: 5, within: 5.minutes, only: :create, name: 'backup-account',
             by: -> { current_user.id }

  def show
  end

  def create
    @codes = current_user.with_lock do
      unless current_user.valid_password?(params[:password].to_s) &&
             current_user.verify_second_factor!(params[:otp_code])
        next
      end

      codes = current_user.generate_otp_backup_codes!
      current_user.update!(otp_backup_codes_generated_at: Time.current,
                           authentication_version: SecureRandom.uuid)
      codes
    end
    unless @codes
      flash.now[:error] = _('The password or code was not recognised.')
      return render :show, status: :unprocessable_content
    end

    Authentication::Session.establish(request, current_user, two_factor: true)
    @continue_path = one_time_password_path
    render 'one_time_passwords/codes'
  end

  private

  def require_account
    return ask_to_login unless current_user
    unless current_user.active? && current_user.totp? &&
           AlaveteliConfiguration.enable_two_factor_auth
      raise ActiveRecord::RecordNotFound
    end
  end
end
