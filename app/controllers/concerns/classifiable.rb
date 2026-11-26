##
# This module contains shared methods for InfoRequest classification
#
module Classifiable
  extend ActiveSupport::Concern

  included do
    before_action :authorise_info_request, only: [:create, :message]
    before_action :ensure_message, if: :message_required_for_state?,
                                   only: :create

    # rubocop:disable Style/ClassVars, Lint/SuppressedException
    @@custom_states_loaded = false
    begin
      require 'customstates'
      include RequestControllerCustomStates
      @@custom_states_loaded = true
    rescue LoadError, NameError
    end
    # rubocop:enable Style/ClassVars, Lint/SuppressedException
  end

  def message
    @described_state = params[:described_state]
    @last_info_request_event_id = info_request.
      last_event_id_needing_description
    @title = case @described_state
             when 'error_message'
               _("I've received an error message")
             when 'requires_admin'
               _('This request requires administrator attention')
             else
               raise ActiveRecord::RecordNotFound
             end

    render 'classifications/message'
  end

  private

  def info_request
    raise NotImplementedError
  end

  def authorise_info_request
    authorize! :update_request_state, info_request
  end

  def classification_params
    params.require(:classification).permit(:described_state, :message)
  end

  def ensure_message
    return if classification_params[:message] || !message_required_for_state?

    redirect_to url_for(
      action: :message,
      url_title: info_request.url_title,
      described_state: classification_params[:described_state]
    )
  end

  # Rejects stale classifications when newer events exist (skipping if
  # only_when_given and param absent). Callers check `return if performed?`.
  def turn_back_stale_answer(only_when_given: false)
    return if only_when_given && !params.key?(:last_info_request_event_id)
    return if params[:last_info_request_event_id].to_i ==
              info_request.last_event_id_needing_description

    flash[:error] = _('The request has been updated since you originally ' \
                      'loaded this page. Please check for any new incoming ' \
                      'messages below, and try again.')
    redirect_to show_request_path(url_title: info_request.url_title)
  end

  def message_required_for_state?
    %w[error_message requires_admin].include?(
      classification_params[:described_state]
    )
  end

  def set_described_state
    described_state = classification_params[:described_state]
    message = classification_params[:message]

    log_params = {
      user_id: current_user.id,
      old_described_state: info_request.described_state,
      described_state: described_state
    }

    log_params[:message] = message if message

    # InfoRequest#set_described_state requires this event to be created first
    event = info_request.log_event('status_update', log_params)
    current_user.increment!(:status_update_count)

    # Make the state change
    info_request.set_described_state(described_state, current_user, message)

    event
  end
end
