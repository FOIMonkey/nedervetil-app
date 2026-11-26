# Lets authorised signed-in users report an InfoRequest for administrator
# attention.
class ReportsController < ApplicationController
  # Full loads let the browser preserve typed form text on Back, since Turbo
  # caches no signed-in pages (doc/FORK.md).
  turbo_drive false, only: %i[new create]

  before_action :set_info_request
  before_action :set_report_reasons
  before_action :check_can_report, only: %i[new create]

  def create
    @reason = params[:reason].to_s
    @message = params[:message] || ""
    if @reason.empty?
      flash[:error] = _("Please choose a reason")
      render "new", status: :unprocessable_content
      return
    end
    if !authenticated?
      flash[:notice] = _("You need to be logged in to report a request " \
                         "for administrator attention")
    elsif @info_request.attention_requested
      flash[:notice] =
        _("This request has already been reported for administrator attention")
    else
      @info_request.report!(@reason, @message, @user)
      flash[:notice] =
        _("This request has been reported for administrator attention")
    end
    redirect_to request_url(@info_request)
  end

  def new
    @title = _("Report request: {{title}}", title: @info_request.title)

    return if authenticated?

    ask_to_login(
      web: _('To report this request'),
      email: _("Then you can report the request '{{title}}'",
               title: @info_request.title),
      email_subject: _('Report an offensive or unsuitable request')
    )
  end

  private

  def set_info_request
    @info_request = InfoRequest.find_by_url_title!(params[:request_url_title])
  end

  def set_report_reasons
    @report_reasons = @info_request.report_reasons
  end

  # Suspended requesters see the banned page; other denied users get 404.
  def check_can_report
    return unless authenticated?
    return if can?(:report, @info_request)
    raise ActiveRecord::RecordNotFound unless authenticated_user.suspended?

    @details = authenticated_user.can_fail_html
    render template: 'user/banned', status: failed_submit_status
  end
end
