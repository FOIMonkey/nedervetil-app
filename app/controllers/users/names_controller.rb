##
# Controller to allow current user to change their name
#
class Users::NamesController < ApplicationController
  before_action :check_user_logged_in, :check_user_suspension, :load_user
  rate_limit to: 5, within: 1.hour, only: :update, name: 'profile-name',
             by: -> { current_user&.id || request.remote_ip }

  def update
    if @edit_user.update(user_params)
      flash[:notice] = _('Name successfully updated.')
      redirect_to user_url(@edit_user)
    else
      render action: 'edit', status: :unprocessable_content
    end
  end

  private

  def user_params
    params.require(:user).permit(:name)
  end

  def check_user_logged_in
    return if authenticated?

    redirect_to frontpage_url,
                error: _('You need to be logged in to change your name')
  end

  # A suspended account can't open its own account page, so it is told here,
  # as it is when it tries to send.
  def check_user_suspension
    return unless current_user.suspended?

    @details = current_user.can_fail_html
    render template: 'user/banned', status: failed_submit_status
  end

  def load_user
    # Don't make changes to the current_user, this could brake the layout as we
    # use name/url_name in the login bar URLs
    @edit_user = User.find_by(url_name: current_user.url_name)
  end
end
