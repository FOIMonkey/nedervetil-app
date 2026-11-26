# Registration preserves the closed-signup policy and never signs in.
class Users::RegistrationsController < Devise::RegistrationsController
  include AuthenticationPages
  include UserSpamCheck
  include TurnstileCheck
  read_only :signups, only: :create
  # Devise would send a signed-in visitor on through after_sign_in_path_for,
  # which claims a saved letter and uses up the remembered return path.
  skip_before_action :require_no_authentication, only: :new
  rate_limit to: 5, within: 1.hour, only: :create, name: 'signup-ip'
  rate_limit to: 3, within: 1.day, only: :create, name: 'signup-email',
             by: -> {
               params.dig(:user_signup, :email).to_s.strip.downcase
             }
  rate_limit to: 30, within: 1.hour, only: :create, name: 'signup-site',
             by: -> { 'site' }
  layout :sign_page_layout
  self.framed_by_sign_in_dialog = true

  def new
    if read_only_feature?(:signups)
      return redirect_to signin_path(sign_page_params)
    end

    @user_signup = User.new
  end

  def create
    data = params.require(:user_signup).permit(:name, :email)
    @user_signup = User.new(data)
    # Unusable placeholder password until mailbox confirmation sets one.
    @user_signup.password = SecureRandom.base64(32)
    if (refusal = turnstile_refusal('signup'))
      flash.now[:error] = refusal
      return render :new, status: :unprocessable_content
    end
    # Validate and strip :taken before lookup to prevent email enumeration.
    @user_signup.validate
    @user_signup.errors.delete(:email, :taken)
    return render :new, status: :unprocessable_content if
      @user_signup.errors.any? || blocked_as_spam?

    existing = User.find_user_by_email(data[:email])
    return signed_up_again(existing) if existing

    # Mail after binding the pending body to the newly-created account, so its
    # separate transfer claim is purpose-bound to exactly that account.
    @user_signup.skip_confirmation_notification!
    return render :new, status: :unprocessable_content unless @user_signup.save

    carry_over_draft_and_return_path
    @user_signup.send_confirmation_instructions
    render 'users/confirmations/check_email'
  rescue ActionController::ParameterMissing
    head :unprocessable_content
  end

  private

  # Re-registering an unconfirmed address updates its name unless suspended
  # or internal admin; confirmation still chooses the password.
  def signed_up_again(existing)
    existing.send_confirmation_while_pending do
      next unless existing.active? && !existing.internal_admin_user?

      existing.update(name: @user_signup.name)
    end
    render 'users/confirmations/check_email'
  end

  def blocked_as_spam?
    spam_user?(@user_signup) &&
      handle_spam_user(@user_signup, 'signup',
                       block: AlaveteliConfiguration.block_spam_signups)
  end

  def carry_over_draft_and_return_path
    pending = PendingRequestDraft.for_browser(session)
    pending&.bind_to(@user_signup)
    @user_signup.draft_claim_for_confirmation = pending&.transfer_token
    return unless params.key?(:r)

    AuthenticationReturn.remember(session, params[:r], user: @user_signup)
  end
end
