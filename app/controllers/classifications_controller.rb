##
# Controller responsible for handling base InfoRequest classification
#
class ClassificationsController < ApplicationController
  include Classifiable
  include ClassificationRefusal

  read_only :classifications, only: :create

  rescue_from ActionController::ParameterMissing do
    flash[:error] = _('Please choose whether or not you got some of the ' \
                      'information that you wanted.')
    redirect_to_info_request
  end

  def create
    remember_last_request(info_request)

    turn_back_stale_answer
    return if performed?

    event = set_described_state

    # If you're not the *actual* requester, e.g. you're doing this just
    # because you are an admin user (not because you also own the request).
    unless info_request.is_actual_owning_user?(current_user)
      # Record who classified someone else's request
      RequestClassification.create!(
        user_id: current_user.id,
        info_request_event_id: event.id
      )

      # Don't give advice on what to do next, as it isn't their request
      flash[:notice] = _('Thank you for updating this request!')
      redirect_to_info_request
      return
    end

    # Display advice for requester on what to do next, as appropriate
    calculated_status = info_request.calculate_status
    partial_path = 'request/describe_notices'
    if template_exists?(calculated_status, [partial_path], true)
      flash[:notice] =
        {
          partial: "#{partial_path}/#{calculated_status}",
          locals: { info_request_id: info_request.id }
        }
    end

    redirect_after_classification(calculated_status)
  end

  private

  def redirect_after_classification(calculated_status)
    case calculated_status
    when 'waiting_response', 'waiting_response_overdue', 'not_held',
      'successful', 'internal_review', 'under_appeal', 'error_message',
      'requires_admin'
      redirect_to_info_request
    when *InfoRequest::State.unhappy
      redirect_to unhappy_url(info_request)
    when 'waiting_clarification', 'user_withdrawn'
      redirect_to respond_to_last_url(info_request)
    when 'gone_postal'
      redirect_to respond_to_last_url(info_request) + '?gone_postal=1'
    else
      return theme_describe_state(info_request) if @@custom_states_loaded

      raise "unknown calculate_status #{info_request.calculate_status}"
    end
  end

  def info_request
    @info_request ||= InfoRequest.find_by!(url_title: params[:url_title])
  end

  def redirect_to_info_request
    redirect_to request_path(info_request)
  end
end
