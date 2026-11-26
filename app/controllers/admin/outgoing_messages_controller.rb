# Lists, searches, edits and resends OutgoingMessage records in the admin
# interface, and deletes any but a request's initial message, logging edits,
# resends and deletions on the request.
class Admin::OutgoingMessagesController < AdminController
  # A flat JSON body keeps the key it had before this controller moved here.
  wrap_parameters :admin_outgoing_message, exclude: []

  include Admin::Searchable

  before_action :set_outgoing_message, only: [:edit, :destroy, :update, :resend]
  before_action :set_info_request, :check_info_request,
                only: [:edit, :destroy, :update, :resend]
  before_action :set_is_initial_message, only: [:edit, :destroy]

  def index
    @title ||= 'Listing outgoing messages'

    @query = params[:query].try(:strip)

    @outgoing_messages = measure_search(
      outgoing_message_scope.
        paginate(page: params[:page], per_page: 100)
    )
  end

  def edit
  end

  def destroy
    if !@is_initial_message && @outgoing_message.destroy
      @outgoing_message.info_request.log_event(
        'destroy_outgoing',
        editor: admin_current_user,
        deleted_outgoing_message_id: @outgoing_message.id
      )

      flash[:notice] = 'Outgoing message successfully destroyed.'
      redirect_to admin_request_url(@outgoing_message.info_request)
    else
      redirect_to edit_admin_outgoing_message_path(@outgoing_message),
                  error: 'Could not destroy the outgoing message.'
    end
  end

  def update
    if @outgoing_message.update_and_log_event(
      **outgoing_message_params,
      event: { editor: admin_current_user },
      options: { skip_body_logging: params[:skip_body_logging] }
    )
      @outgoing_message.expire

      flash[:notice] = 'Outgoing message successfully updated.'
      redirect_to admin_request_url(@outgoing_message.info_request)
    else
      render action: 'edit', status: :unprocessable_content
    end
  end

  def resend
    # Raises for any message type but the two sent below.
    @outgoing_message.prepare_message_for_resend

    mail_message = case @outgoing_message.message_type
                   when 'initial_request'
                     OutgoingMailer.initial_request(
                       @outgoing_message.info_request,
                       @outgoing_message
                     ).deliver_now
                   when 'followup'
                     OutgoingMailer.followup(
                       @outgoing_message.info_request,
                       @outgoing_message,
                       @outgoing_message.incoming_message_followup
                     ).deliver_now
                   end

    @outgoing_message.record_email_delivery(
      mail_message.to_addrs.join(', '),
      mail_message.message_id,
      'resent'
    )
    @outgoing_message.info_request.reopen_to_new_responses

    flash[:notice] = "Outgoing message resent"
    redirect_to admin_request_url(@outgoing_message.info_request)
  end

  private

  # Newest first, as the admin lists of events and imports are. A search has
  # an order of its own.
  def outgoing_message_scope
    return base_scope.order(id: :desc) if @query.blank?

    base_scope.search_scope(@query, admin_mode: true)
  end

  def base_scope
    OutgoingMessage
  end

  def outgoing_message_params
    if params[:outgoing_message]
      params.require(:outgoing_message).
        permit(:prominence, :prominence_reason, :body, :tag_string, :from_name)
    else
      {}
    end
  end

  def set_outgoing_message
    @outgoing_message = OutgoingMessage.find(params[:id])
  end

  def set_info_request
    @info_request = @outgoing_message.info_request
  end

  def check_info_request
    return if can? :admin, @info_request

    raise ActiveRecord::RecordNotFound
  end

  def set_is_initial_message
    @is_initial_message = @outgoing_message == last_event_message
  end

  def last_event_message
    @outgoing_message.
      info_request.
        last_event_forming_initial_request.
          try(:outgoing_message)
  end
end
