module Deadlines
  # Changes a stage's due date for a request, and restores the original.
  class AdjustmentsController < BaseController
    # It rewrites core's due dates, so it is read-only whenever core's status
    # form is.
    read_only :classifications

    def create
      stage = params[:stage].to_s
      unless Adjustment::STAGES.include?(stage)
        raise ActiveRecord::RecordNotFound
      end

      due_on =
        begin
          Date.iso8601(params[:due_on].to_s)
        rescue StandardError
          nil
        end
      Adjustment.apply!(@info_request,
                        stage: stage,
                        user: current_user,
                        due_on: due_on,
                        reason: params[:reason].to_s,
                        note: params[:note].to_s.strip)
      flash[:notice] = _('Due date changed to {{date}}.',
                         date: due_on.strftime('%-d %B %Y'))
      redirect_to back_to_request
    rescue ActiveRecord::RecordInvalid => e
      problems = e.record.errors.full_messages.to_sentence.downcase
      flash[:error] = PlainTextTranslation._(
        'The due date wasn’t changed: {{problems}}.', problems: problems
      )
      redirect_to back_to_request
    rescue ArgumentError
      flash[:error] = _('There is no deadline to change at this stage of ' \
                        'the request.')
      redirect_to back_to_request
    end

    def destroy
      stage = params[:stage].to_s
      unless Adjustment::STAGES.include?(stage)
        raise ActiveRecord::RecordNotFound
      end

      Adjustment.clear!(@info_request, stage)
      flash[:notice] = _('The original due date has been restored.')
      redirect_to back_to_request
    end

    private

    def back_to_request
      show_request_path(@info_request.url_title, anchor: 'deadlines')
    end
  end
end
