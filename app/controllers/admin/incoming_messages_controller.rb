# Allows admins to update prominence and tags on an IncomingMessage, or destroy
# incoming messages individually or in bulk, logging each action on the request.
class Admin::IncomingMessagesController < AdminController
  # A flat JSON body keeps the key it had before this controller moved here.
  wrap_parameters :admin_incoming_message, exclude: []

  before_action :set_incoming_message, only: [:edit, :update, :destroy]
  before_action :set_info_request, :check_info_request

  def edit
  end

  def update
    old_prominence = @incoming_message.prominence
    old_prominence_reason = @incoming_message.prominence_reason
    old_tag_string = @incoming_message.tag_string
    if @incoming_message.update(incoming_message_params)
      @incoming_message.info_request.log_event(
        'edit_incoming',
        incoming_message_id: @incoming_message.id,
        editor: admin_current_user,
        old_prominence: old_prominence,
        prominence: @incoming_message.prominence,
        old_prominence_reason: old_prominence_reason,
        prominence_reason: @incoming_message.prominence_reason,
        old_tag_string: old_tag_string,
        tag_string: @incoming_message.tag_string
      )
      @incoming_message.info_request.expire
      flash[:notice] = 'Incoming message successfully updated.'
      redirect_to admin_request_url(@incoming_message.info_request)
    else
      render action: 'edit', status: :unprocessable_content
    end
  end

  def destroy
    @incoming_message.destroy!
    @incoming_message.info_request.log_event(
      'destroy_incoming',
      editor: admin_current_user,
      deleted_incoming_message_id: @incoming_message.id,
      storage_keys: @incoming_message.storage_keys
    )
    # expire cached files
    @incoming_message.info_request.expire(preserve_database_cache: true)
    flash[:notice] = 'Incoming message successfully destroyed.'
    redirect_to admin_request_url(@incoming_message.info_request)
  end

  def bulk_destroy
    if params[:commit] == "No"
      return redirect_to(admin_request_url(@info_request))
    end

    ids = params[:ids]
    unless ids.is_a?(String) && ids.present?
      raise ActionController::ParameterMissing, :ids
    end

    @incoming_messages = @info_request.incoming_messages.
                           where(id: ids.split(","))
    return unless params[:commit] == "Yes"

    errors = []
    @incoming_messages.each do |message|
      message.destroy!
      @info_request.log_event(
        'destroy_incoming',
        editor: admin_current_user,
        deleted_incoming_message_id: message.id,
        storage_keys: message.storage_keys
      )
    rescue StandardError => e
      Rails.logger.error(
        "Unable to destroy incoming message #{message.id}: #{e.class}"
      )
      errors << message.id
    end
    @info_request.expire(preserve_database_cache: true)
    if errors.empty?
      flash[:notice] = "Incoming messages successfully destroyed."
    else
      flash[:error] = <<-EOF.strip_heredoc
        Only some incoming messages were destroyed.
        Incoming Messages #{ errors.join(', ') } could not be destroyed.
        Try destroying them individually.
      EOF
    end
    redirect_to(admin_request_url(@info_request))
  end

  private

  def incoming_message_params
    if params[:incoming_message]
      params.require(:incoming_message).permit(
        :prominence, :prominence_reason, :tag_string
      )
    else
      {}
    end
  end

  def set_incoming_message
    @incoming_message = IncomingMessage.find(params[:id])
  end

  def set_info_request
    @info_request = @incoming_message&.info_request || InfoRequest.find(
      params[:request_id]
    )
  end

  def check_info_request
    return if can? :admin, @info_request

    raise ActiveRecord::RecordNotFound
  end
end
