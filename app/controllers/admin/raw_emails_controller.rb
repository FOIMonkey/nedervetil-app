# Copyright (c) 2007 UK Citizens Online Democracy. All rights reserved.
# Email: hello@mysociety.org; WWW: http://www.mysociety.org/

# Displays a stored RawEmail as HTML or .eml download in the admin interface,
# suggesting destination requests and authorities for holding-pen mail.
class Admin::RawEmailsController < AdminController
  # A flat JSON body keeps the key it had before this controller moved here.
  wrap_parameters :admin_raw_email, exclude: []

  skip_before_action :html_response

  before_action :set_raw_email, only: [:show]
  before_action :set_info_request, :check_info_request

  def show
    respond_to do |format|
      format.html do
        context = Admin::HoldingPenContext.new(@raw_email)
        @holding_pen = context.in_holding_pen?

        if @holding_pen
          @public_bodies = context.public_bodies
          @guessed_info_requests = context.guessed_info_requests
          @rejected_reason = context.rejected_reason
        end
      end

      format.eml do
        return head :not_found unless @raw_email.kept?

        render body: @raw_email.data, content_type: 'message/rfc822'
      end
    end
  end

  private

  def set_raw_email
    @raw_email = RawEmail.find(params[:id])
  end

  def set_info_request
    @info_request = @raw_email.incoming_message.info_request
  end

  def check_info_request
    return if can? :admin, @info_request

    raise ActiveRecord::RecordNotFound
  end
end
