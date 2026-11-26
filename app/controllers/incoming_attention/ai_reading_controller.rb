module IncomingAttention
  # The account page that switches AI reading of new replies on or off.
  class AiReadingController < ::ApplicationController
    read_only only: :update
    before_action :require_sign_in

    def edit
      @opted_out = OptOut.opted_out?(current_user)
    end

    def update
      # Only an explicit choice changes the setting.
      unless %w[on off].include?(params[:ai_reading])
        flash[:error] = _('Choose On or Off.')
        return redirect_to profile_ai_reading_path
      end
      off = params[:ai_reading] == 'off'
      OptOut.set!(current_user, off)
      flash[:notice] =
        if off
          _('New replies to your requests will not be read by AI.')
        else
          _('New replies to your requests will be read by AI.')
        end
      redirect_to profile_ai_reading_path
    end

    private

    def require_sign_in
      redirect_to signin_path(r: profile_ai_reading_path) unless authenticated?
    end
  end
end
