# Copyright (c) 2007 UK Citizens Online Democracy. All rights reserved.
# Email: hello@mysociety.org; WWW: http://www.mysociety.org/

# Displays a user's account page, toggles email alert preferences and serves
# the Tor sign-up block response.
class UserController < ApplicationController
  before_action :normalize_url_name, only: :show
  before_action :set_display_user, only: :show
  before_action :set_no_crawl_headers_if_suspended, only: :show

  # Non-owners are blocked by PrivateArchive; ?view=requests goes to inbox.
  def show
    long_cache
    @is_you = current_user_is_display_user?
    return unless @is_you && params[:view] == 'requests'

    redirect_to(alaveteli_pro_info_requests_path)
  end

  # A webserver level redirect can be used to redirect from the signup action to
  # prevent spam signups from Tor.
  def tor
    long_cache

    msg = _('Signups from Tor have been blocked due to extensive misuse. ' \
            'Please contact us if this is a problem for you.')

    render_plain_text(msg, status: :forbidden)
  end

  def set_receive_email_alerts
    unless authenticated?
      redirect_to frontpage_url,
                  error: _("You need to be logged in to edit your profile.")
      return
    end
    @user.receive_email_alerts = params.require(:receive_email_alerts)
    @user.save!
    redirect_to SafeRedirect.new(params[:came_from]).path
  end

  private

  def set_no_crawl_headers_if_suspended
    set_no_crawl_headers if @display_user&.suspended?
  end

  def normalize_url_name
    unless MySociety::Format.simplify_url_part(params[:url_name], 'user') ==
           params[:url_name]
      redirect_to(
        url_name: MySociety::Format.simplify_url_part(
          params[:url_name], 'user'
        ),
        status: :moved_permanently
      )
    end
  end

  def set_display_user
    @display_user =
      User.where(email_confirmed: true).friendly.find(params[:url_name])
  end

  def current_user_is_display_user?
    current_user&.id == @display_user.id
  end
end
