# All administrative controllers share the current full-authentication gate.
class AdminController < ApplicationController
  layout 'admin'
  before_action :authenticate

  def admin_current_user
    current_user&.url_name
  end

  def handle_unverified_request
    raise ActionController::InvalidAuthenticityToken
  end

  private

  def authenticate
    return if Authentication::Session.admin?(request)
    raise ActiveRecord::RecordNotFound if current_user

    ask_to_login
  end
end
