module AttachmentManagement
  # Anyone who may not manage the attachment, and any unknown ID, gets a 404,
  # so an ID or URL on its own reveals nothing.
  class BaseController < ::ApplicationController
    # Editors hold unsaved state on the page and rely on full-load
    # beforeunload prompts (doc/FORK.md).
    turbo_drive false

    include FileDelivery

    before_action :require_sign_in
    before_action :find_attachment
    before_action :authorize_management
    helper_method :redact_only?

    private

    def sign_in_reason
      { web: _('To manage an attachment'),
        email: _('Then you can manage the attachment.'),
        email_subject: _('Sign in to manage an attachment') }
    end

    def find_attachment
      @attachment = FoiAttachment.find_by(id: params[:attachment_id]) or
        raise ActiveRecord::RecordNotFound
      @incoming_message = @attachment.incoming_message
      @info_request = @attachment.info_request
    end

    def authorize_management
      raise ActiveRecord::RecordNotFound unless
        can?(:manage_attachment, @attachment)
    end

    def redact_only?
      !can?(:replace_attachment, @attachment)
    end

    def publish_instead
      if can?(:admin, @info_request) ||
         !can?(:publish_from_reply, @incoming_message)
        return
      end

      redirect_to publish_reply_path(url_title: @info_request.url_title,
                                     message_id: @incoming_message.id)
    end

    def attachment_available?
      !@attachment.erased? && !@attachment.masking_failed? &&
        @attachment.file.attached?
    end

    def attachment_bytes
      @attachment_bytes ||= @attachment.body.to_s
    end

    def attachment_sha256
      @attachment_sha256 ||= Digest::SHA256.hexdigest(attachment_bytes)
    end

    def attachment_previews
      @attachment_previews ||= Previews.new(
        attachment_id: @attachment.id,
        sha256: attachment_sha256,
        content_type: @attachment.content_type
      ) { attachment_bytes }
    end

    def attachment_text
      convert_string_to_utf8(attachment_bytes.dup, 'UTF-8').string
    end

    def capabilities
      @capabilities ||= Capabilities.new(@attachment)
    end

    def send_file_bytes(bytes, filename:, content_type:, inline: false)
      # PDF previews retain the application CSP instead of the file sandbox.
      csp = (FileDelivery::ATTACHMENT_CSP unless
               content_type == 'application/pdf')
      send_file_content(bytes, filename: filename, content_type: content_type,
                               inline: inline, csp: csp)
    end

    def send_png(path)
      send_png_content(path: path.to_s)
    end

    def page_param
      Integer(params[:page], exception: false) ||
        raise(ActiveRecord::RecordNotFound)
    end
  end
end
