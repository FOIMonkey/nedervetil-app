# Managing a User's email alerts.
class Users::EmailAlertsController < ApplicationController
  include AuthenticationPages

  def show
    @token = raw_token
    return if User::EmailAlerts.valid_token?(@token)

    redirect_to root_path, error: _('Invalid token')
  end

  def destroy
    return if User::EmailAlerts.disable_by_token(raw_token)

    redirect_to root_path, error: _('Invalid token')
  end

  private

  def raw_token
    CGI.unescape(params[:token].to_s)
  end
end
