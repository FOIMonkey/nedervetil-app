##
# Controller to manage FoiAttachment instances
#
class Admin::FoiAttachmentsController < AdminController
  include FileDelivery

  before_action :set_foi_attachment, :set_incoming_message, :set_info_request
  before_action :check_info_request

  # Show unmasked main body if readable; degrade gracefully if mail is unread.
  def edit
    return unless @foi_attachment.main_body_part? && raw_email_available?

    @unmasked_body = @foi_attachment.unmasked_body
  rescue MailHandler::ReadRefused, RawEmail::Erasable::ErasedError
    @unmasked_body = nil
  end

  # The part as it is in the email, for an admin to inspect when masking hit
  # a fault on it. Download only: never rendered, cached or indexed.
  def download_unmasked
    raise ActiveRecord::RecordNotFound unless @foi_attachment.masking_failed?
    if @foi_attachment.erased? || !raw_email_available?
      raise ActiveRecord::RecordNotFound
    end

    original = @foi_attachment.unmasked_body
    # At warn, so production (RAILS_LOG_LEVEL=warn) keeps it as a record.
    Rails.logger.warn(
      '[masking] admin original attachment download ' \
      "attachment=#{@foi_attachment.id} admin=#{current_user&.id}"
    )
    response.headers['cache-control'] = 'private, no-store'
    response.headers['x-robots-tag'] = 'noindex, nofollow, noarchive'
    send_file_content(original,
                      filename: "attachment-#{@foi_attachment.id}-unmasked.bin",
                      content_type: 'application/octet-stream',
                      csp: FileDelivery::DOCUMENT_CSP)
  rescue FoiAttachment::MissingError, RawEmail::Erasable::ErasedError
    raise ActiveRecord::RecordNotFound
  end

  private

  def set_foi_attachment
    @foi_attachment = FoiAttachment.find(params[:id])
  end

  def set_incoming_message
    @incoming_message = @foi_attachment&.incoming_message
  end

  def set_info_request
    @info_request = @incoming_message&.info_request
  end

  def check_info_request
    return if can? :admin, @info_request

    raise ActiveRecord::RecordNotFound
  end

  def raw_email_available?
    @foi_attachment.raw_email&.kept? && !@foi_attachment.raw_email_erased?
  end
end
