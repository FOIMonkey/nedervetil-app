module IncomingAttention
  # The account page for choosing a daily summary or an email for each reply.
  class EmailsController < ::ApplicationController
    read_only only: :update
    before_action :require_sign_in

    def edit
      @instant = InstantEmails.on?(current_user)
    end

    def update
      unless %w[daily each].include?(params[:emails])
        flash[:error] = _('Choose how you get emails about replies.')
        return redirect_to profile_emails_path
      end
      InstantEmails.set!(current_user, params[:emails] == 'each')
      flash[:notice] =
        if params[:emails] == 'each'
          _('You’ll get an email for each reply.')
        else
          _('You’ll get one summary a day.')
        end
      redirect_to profile_emails_path
    end

    private

    def require_sign_in
      redirect_to signin_path(r: profile_emails_path) unless authenticated?
    end
  end
end
