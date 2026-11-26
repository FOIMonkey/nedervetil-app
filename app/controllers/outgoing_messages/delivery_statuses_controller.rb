# Displays an OutgoingMessage's delivery status and associated mail server log
# lines (redacted for non-admins) to readers permitted to view the request.
class OutgoingMessages::DeliveryStatusesController < ApplicationController
  before_action :set_outgoing_message, :check_prominence

  def show
    @title = _('Delivery Status for Outgoing Message #{{id}}',
               id: @outgoing_message.id)

    @delivery_status = @outgoing_message.delivery_status

    request = @outgoing_message.info_request
    @show_mail_server_logs = can?(:read, request)

    return unless @show_mail_server_logs

    @mail_server_logs = @outgoing_message.mail_server_logs.map do |log|
      log.line(redact: cannot?(:admin, request))
    end
  end

  protected

  def set_outgoing_message
    @outgoing_message = OutgoingMessage.find(params[:outgoing_message_id])
  end

  def check_prominence
    unless can?(:read, @outgoing_message) && \
           can?(:read, @outgoing_message.info_request)
      render_hidden('request/_prominence',
                    locals: { prominenceable: @outgoing_message })
    end
  end
end
