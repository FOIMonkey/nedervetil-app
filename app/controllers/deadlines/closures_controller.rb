module Deadlines
  # Marks a request complete with a final status, and reopens it.
  class ClosuresController < BaseController
    read_only :classifications

    def create
      state = params[:final_state].to_s
      unless Closure::FINAL_STATES.include?(state)
        flash[:error] = _('Choose the final status before marking the ' \
                          'request complete.')
        return redirect_back_to_origin
      end

      Closure.close!(@info_request,
                     user: current_user,
                     final_state: state,
                     last_event_id: params[:last_event_id])
      flash[:notice] = PlainTextTranslation._(
        '“{{title}}” marked complete: {{status}}.',
        title: @info_request.title,
        status: InfoRequest::State.short_description(state)
      )
      redirect_back_to_origin
    rescue Closure::Stale
      flash[:error] = _('The request has changed since the page was loaded ' \
                        '(there may be a new reply). Check it, then try ' \
                        'again.')
      redirect_back_to_origin
    rescue Closure::UnreadReplies
      flash[:error] = _('This request has a reply you haven’t read yet. Read ' \
                        'it first, then mark the request complete.')
      redirect_back_to_origin
    end

    def destroy
      Closure.reopen!(@info_request)
      flash[:notice] = _('The request is open again. Its status is unchanged.')
      redirect_back_to_origin
    end

    private

    # Fixed destinations only to prevent open redirects.
    def redirect_back_to_origin
      if params[:return_to] == 'dashboard'
        redirect_to alaveteli_pro_dashboard_path(
          anchor: 'deadlines-action_required-title'
        )
      else
        redirect_to show_request_path(@info_request.url_title,
                                      anchor: 'deadlines')
      end
    end
  end
end
