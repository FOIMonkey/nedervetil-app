##
# Controller to serve FoiAttachment records.
#
class AttachmentsController < ApplicationController
  include InfoRequestHelper
  include FileDelivery

  skip_before_action :html_response, :store_gettext_locale

  before_action :find_info_request, :find_incoming_message, :find_attachment

  before_action :authenticate_attachment
  before_action :set_cors

  around_action :ensure_masked

  def show
    send_file_content(@attachment.body,
                      filename: @attachment.display_filename,
                      content_type: content_type,
                      csp: FileDelivery::ATTACHMENT_CSP)
  end

  private

  def find_info_request
    @info_request = InfoRequest.find_by!(url_title: params[:request_url_title])
  end

  def find_incoming_message
    @incoming_message = @info_request.incoming_messages.find(
      params[:incoming_message_id]
    )
  end

  def find_attachment
    return if cannot?(:read, @info_request) || cannot?(:read, @incoming_message)

    attachments = @incoming_message.get_attachments_for_display
    numbered = attachments.find { |attachment|
      attachment.url_part_number == part_number
    }
    return if numbered && !numbered.erased? && cannot?(:read, numbered)

    @attachment =
      IncomingMessage.get_attachment_by_url_part_number_and_filename!(
        attachments.select { |attachment|
          attachment.erased? || can?(:read, attachment)
        },
        part_number,
        original_filename
      )
  end

  def authenticate_attachment
    # Test for hidden
    if cannot?(:read, @info_request)
      request.format = :html
      return render_hidden
    end
    if cannot?(:read, @incoming_message)
      request.format = :html
      return render_hidden('request/hidden_correspondence')
    end

    if @attachment
      # Check for erased attachment
      if @attachment.erased?
        request.format = :html
        render_hidden('request/erased_attachment')
      end

    elsif params[:file_name]
      # If we can't find the right attachment, redirect to the incoming message:
      redirect_to incoming_message_url(@incoming_message), status: 303
    else
      render plain: 'Directory listing not allowed', status: 403
    end
  end

  # Masking always leaves a copy for the requester, even after a fault
  # (FoiAttachment::Maskable#masking_outcome), so this waits for it.
  def ensure_masked
    if @attachment.masked?
      yield
    else
      @attachment.mask_later

      Timeout.timeout(5) do
        until @attachment.masked?
          sleep 0.5
          @attachment.reload
        end

        redirect_to(request.fullpath)
      end
    end

  rescue Timeout::Error, ActiveRecord::RecordNotFound
    redirect_to wait_for_attachment_mask_path(
      @attachment.to_signed_global_id,
      referer: verifier.generate(request.fullpath)
    )
  end

  def set_cors
    # Allow CSVs to be explored in a Datasette instance
    return unless @attachment.content_type == 'text/csv'

    headers['access-control-allow-origin'] = '*'
    headers['access-control-request-method'] = 'GET'
  end

  def part_number
    params[:part].to_i
  end

  def original_filename
    params[:file_name]
  end

  def content_type
    # we don't use @attachment.content_type here, as we want same mime type
    # when cached in cache_attachments above
    AlaveteliFileTypes.filename_to_mimetype(params[:file_name]) ||
      'application/octet-stream'
  end

  def verifier
    Rails.application.message_verifier('AttachmentsController')
  end
end
