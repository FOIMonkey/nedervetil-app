# Renders and processes the form for visitors or signed-in users to suggest a
# new authority or an updated request email, with honeypot and Turnstile checks.
class PublicBodyChangeRequestsController < ApplicationController
  include TurnstileCheck

  before_action :catch_spam, only: [:create]
  before_action :set_turnstile_required
  rate_limit to: 10, within: 1.hour, only: :create, name: 'change-request'

  def new
    @change_request =
      PublicBodyChangeRequest.new

    if params[:body]
      @change_request.public_body =
        PublicBody.find_by_url_name_with_historic(params[:body])
    end

    @title =
      if @change_request.public_body
        _('Ask us to update the email address for {{public_body_name}}',
          public_body_name: @change_request.public_body.name)
      else
        _('Ask us to add an authority')
      end
  end

  def create
    @change_request =
      PublicBodyChangeRequest.from_params(change_request_params, @user)

    refusal = turnstile_refusal('change_request') if @turnstile_required
    if refusal
      @change_request.errors.add(:base, refusal)
      render action: 'new', status: :unprocessable_content
    elsif @change_request.save
      @change_request.send_message
      redirect_to frontpage_url, notice: @change_request.thanks_notice
    else
      render action: 'new', status: :unprocessable_content
    end
  end

  private

  def catch_spam
    return unless change_request_params.key?(:comment)

    redirect_to frontpage_url unless change_request_params[:comment].empty?
  end

  def change_request_params
    params.require(:public_body_change_request)
  end

  def set_turnstile_required
    @turnstile_required = !@user
  end
end
