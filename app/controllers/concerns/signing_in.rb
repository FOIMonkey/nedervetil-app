# Session authentication, sign-in redirects, and signed-out origin checks for
# ApplicationController. All methods stay private so routes cannot reach them
# as controller actions.
module SigningIn
  extend ActiveSupport::Concern

  included do
    class_attribute :framed_by_sign_in_dialog, default: false
    helper_method :sign_page_params, :current_user
  end

  private

  def modal_dialog?
    params[:modal].to_s == '1'
  end

  def in_sign_in_dialog?
    framed_by_sign_in_dialog && modal_dialog?
  end

  def sign_page_layout
    in_sign_in_dialog? ? 'no_chrome' : 'default'
  end

  def sign_page_params
    { r: (Authentication::ReturnPath.normalize(params[:r]) if params.key?(:r)),
      modal: (1 if modal_dialog?) }.compact
  end

  def clear_session_credentials
    request.env['warden']&.logout(:user)
    reset_session
    @user = @current_user = @current_ability = nil
  end

  def complete_authentication(user, two_factor:, backup_codes_remaining: nil)
    carry = session.to_hash.slice(
      'authentication_return',
      'pending_request_draft',
      'pending_draft_transfer'
    )
    reset_session
    carry.each { |key, value| session[key] = value }
    Authentication::Session.establish(request, user, two_factor: two_factor)
    @current_user = @user = user
    @current_ability = nil
    unless backup_codes_remaining.nil?
      flash[:notice] = { partial: 'one_time_passwords/backup_code_used',
                         locals: { remaining: backup_codes_remaining } }
    end
    @continue_path = after_sign_in_path_for(user)
    if modal_dialog?
      render 'users/sessions/complete'
    else
      redirect_to @continue_path, status: :see_other
    end
  end

  # Where an account goes once signed in. Devise asks this too.
  def after_sign_in_path_for(user)
    destination = AuthenticationReturn.consume(session, user)
    draft = PendingRequestDraft.claim(session, user)
    return destination unless draft

    flash[:notice] ||=
      _('Your request is saved as a draft. Review it before sending.')
    new_alaveteli_pro_info_request_path(draft_id: draft.id)
  end

  # Only emit a CSRF token when authenticated, avoiding anonymous sessions.
  def form_authenticity_token(**args)
    super if authenticated?
  end

  def authenticated?(as: nil)
    if as
      authenticated_user == as
    else
      authenticated_user.present?
    end
  end

  # Prompt sign-in on GET when sign_in_reason is set; otherwise fail closed
  # with 404.
  def require_sign_in
    return if authenticated?
    raise ActiveRecord::RecordNotFound unless request.get? && sign_in_reason

    ask_to_login(**sign_in_reason)
  end

  def sign_in_reason; end

  # Only the bounded request-composition handoff may survive signing in;
  # legacy reason/keep keywords are ignored and never stored or replayed.
  def ask_to_login(as: nil, **_reason_params)
    if as && authenticated? && current_user != as
      @reason_params = { user_name: as.name }
      render template: 'user/wrong_user', status: failed_submit_status
      return
    end

    pending_draft = capture_pending_draft
    destination = return_destination(pending_draft)
    response.headers['cache-control'] = 'private, no-store'
    link_params = { r: destination, modal: modal_dialog? ? 1 : nil }
    if pending_draft && !read_only_feature?(:signups)
      redirect_to signup_path(link_params)
    else
      redirect_to signin_path(link_params)
    end
  end

  def capture_pending_draft
    if controller_path == 'request' && action_name == 'new' && request.post?
      pending_draft = PendingRequestDraft.capture(session,
        title: params.dig(:info_request, :title),
        body: params.dig(:outgoing_message, :body),
        public_body_id: params.dig(:info_request, :public_body_id))
    end
    pending_draft
  end

  def return_destination(pending_draft)
    path = request.fullpath
    if controller_path.start_with?('alaveteli_pro/') && params[:draft_id]
      path = new_alaveteli_pro_info_request_path(draft_id: params[:draft_id])
    end
    destination = Authentication::ReturnPath.normalize(path)
    destination = nil if pending_draft ||
                         destination == Authentication::ReturnPath::DEFAULT
    destination
  end

  def authenticated_user
    return @current_user if defined?(@current_user)

    @current_user = Authentication::Session.user(request)
  end

  alias current_user authenticated_user

  # Default layout shows user in corner, so needs access to it
  def authentication_check
    @user = authenticated_user
  end

  # Reject signed-out non-GET requests without a same-origin Origin or Referer
  # (including missing headers or "null").
  def verify_signed_out_origin
    return if request.get? || request.head? || !protect_against_forgery?

    source = request.origin.presence || request.referer.presence
    return if source && same_origin?(source)

    raise ActionController::InvalidAuthenticityToken,
          "Signed-out #{request.request_method} from #{source}"
  end

  def same_origin?(url)
    uri = URI.parse(url)
    return false unless uri.is_a?(URI::HTTP) && uri.host

    origin = "#{uri.scheme}://#{uri.host}"
    origin += ":#{uri.port}" unless uri.port == uri.default_port
    origin == request.base_url
  rescue URI::Error
    false
  end
end
