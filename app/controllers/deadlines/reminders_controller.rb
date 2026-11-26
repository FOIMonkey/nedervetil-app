module Deadlines
  # Sends overdue reminders for a request under core's follow-up guards.
  class RemindersController < BaseController
    read_only :followups

    def create
      Reminder.send!(@info_request, current_user)
      flash[:notice] = PlainTextTranslation._(
        'Reminder sent to {{authority}}.',
        authority: @info_request.public_body.name
      )
      redirect_back_to_origin
    rescue Reminder::NothingLate
      flash[:notice] = _('There’s nothing to remind them about now.')
      redirect_back_to_origin
    rescue Reminder::Failed
      flash[:error] = _('The reminder couldn’t be sent. Contact us and ' \
                        'we’ll send it.')
      redirect_back_to_origin
    end

    private

    def find_request
      @info_request = find_info_request!(:send_reminder,
                                         id: params[:request_id])
      closed = @info_request.allow_new_responses_from == 'nobody'
      raise ActiveRecord::RecordNotFound if closed
    end

    # Fixed destinations only to prevent open redirects.
    def redirect_back_to_origin
      if params[:return_to] == 'home'
        redirect_to alaveteli_pro_dashboard_path
      else
        redirect_to show_request_path(@info_request.url_title)
      end
    end
  end
end
