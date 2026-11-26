# app/controllers/alaveteli_pro/base_controller.rb
#
# Copyright (c) 2008 UK Citizens Online Democracy. All rights reserved.
# Email: hello@mysociety.org; WWW: http://www.mysociety.org/

# Base controller for the inbox, open to every signed-in account
# (alaveteli_pro naming is kept for theme compatibility; see doc/FORK.md).
class AlaveteliPro::BaseController < ApplicationController
  before_action :require_inbox_sign_in
  before_action :set_in_pro_area

  def set_in_pro_area
    @in_pro_area = true
  end

  private

  # Prompt sign-in for all signed-out inbox requests, including non-GET
  # (unlike SigningIn#require_sign_in, which returns 404 on non-GET).
  def require_inbox_sign_in
    return if authenticated?

    ask_to_login(
      web: _('To access {{site_name}}', site_name: site_name),
      email: _('Then you can access {{site_name}}', site_name: site_name)
    )
  end
end
