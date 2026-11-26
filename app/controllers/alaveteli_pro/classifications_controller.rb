##
# Controller responsible for handling Alaveteli Pro InfoRequest classification
#
class AlaveteliPro::ClassificationsController < AlaveteliPro::BaseController
  include Classifiable

  read_only :classifications, only: :create

  skip_before_action :require_inbox_sign_in

  def create
    # Reply forms pass an event ID to catch stale replies; the sidebar status
    # picker omits it intentionally and updates regardless.
    turn_back_stale_answer(only_when_given: true)
    return if performed?

    set_described_state

    answer = Deadlines::Reply::ANSWERS.key(classification_params[:described_state])
    # The page says what they answered, and focus lands on that line.
    flash[:notice] = _('Status updated.') unless answer
    redirect_to show_request_path(
      url_title: info_request.url_title,
      anchor: answer ? 'receipt-answer' : nil
    )
  end

  private

  def info_request
    @info_request ||= InfoRequest.find_by!(url_title: params[:url_title])
  end
end
