# Email changes use a separate account-bound action and fresh credentials.
class Users::EmailChangesController < ApplicationController
  include AuthenticationPages
  include UserSpamCheck
  before_action :require_account
  rate_limit to: 5, within: 15.minutes, only: [:create, :update],
             name: 'email-change'
  rate_limit to: 5, within: 15.minutes, only: [:create, :update],
             name: 'email-change-account',
             by: -> { current_user.id }

  def new
  end

  def create
    data = params.require(:signchangeemail).permit(:new_email, :password,
      :otp_attempt)
    @new_email = data[:new_email] # the form keeps it when it is shown again
    address = data[:new_email].to_s.strip.downcase
    unless MySociety::Validate.is_valid_email(address)
      unless current_user.valid_password?(data[:password].to_s)
        return refuse(:new)
      end

      flash.now[:error] = _('Please enter a valid email address.')
      return render :new, status: :unprocessable_content
    end

    passed = current_user.valid_password?(data[:password].to_s)
    if current_user.otp_required_for_login
      passed &&= current_user.verify_second_factor!(data[:otp_attempt])
    end
    return refuse(:new) unless passed

    UserMailer.changeemail_requested(current_user, address).deliver_now
    unless User.find_user_by_email(address)
      token = PendingEmailChange.issue(current_user, address)
      url = confirm_email_change_url(email_token: token,
                                     **AuthenticationMailer.origin)
      UserMailer.changeemail_confirm(current_user, address, url).deliver_now
    end
    render 'user/signchangeemail_confirm'
  end

  def show
    @email_change = PendingEmailChange.find_by_token(params[:email_token])
    return if @email_change&.usable_for?(current_user)

    raise ActiveRecord::RecordNotFound
  end

  def update
    change = PendingEmailChange.find_by_token(params[:email_token])
    data = params.require(:signchangeemail).permit(:password, :otp_attempt)
    unless change&.complete(current_user, password: data[:password].to_s,
                                          otp: data[:otp_attempt].to_s)
      # The link no longer works for this account: no page to show.
      usable = change&.usable_for?(current_user)
      raise ActiveRecord::RecordNotFound unless usable

      @email_change = change
      return refuse(:show)
    end

    handle_spam_user(current_user, 'email change',
      block: false) if spam_user?(current_user)
    clear_session_credentials
    redirect_to signin_path,
      notice: _('Email address changed. Please sign in.'), status: :see_other
  end

  private

  # The form again, with a message that doesn't say which part was wrong.
  def refuse(template)
    flash.now[:error] =
      if current_user.otp_required_for_login
        _('The password or code was not recognised.')
      else
        _('That password was not recognised.')
      end
    render template, status: :unprocessable_content
  end

  def require_account
    return ask_to_login unless current_user
    raise ActiveRecord::RecordNotFound unless current_user.active?
  end
end
