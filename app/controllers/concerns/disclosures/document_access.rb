module Disclosures
  # Shared lookup, ability checks, safe file delivery and route helpers mixed
  # into public and admin Disclosures controllers.
  module DocumentAccess
    extend ActiveSupport::Concern
    include FileDelivery

    included do
      helper_method :manager?, :publish_flow_redact_path,
                    :publish_flow_check_path, :document_withdrawal_path
    end

    private

    def document_withdrawal_path(document)
      if can?(:admin, document)
        admin_disclosure_withdraw_document_path(document)
      else
        disclosure_withdraw_document_path(document)
      end
    end

    def publish_flow_redact_path(document)
      message = document.incoming_message
      return unless message &&
                    message.info_request_id == document.info_request_id &&
                    can?(:publish_from_reply, message) &&
                    can?(:publish_own_document, document)

      publish_reply_redact_path(url_title: message.info_request.url_title,
                                message_id: message.id,
                                id: document)
    end

    def publish_flow_check_path(document)
      return unless publish_flow_redact_path(document)

      message = document.incoming_message
      publish_reply_check_path(url_title: message.info_request.url_title,
                               message_id: message.id)
    end

    def sign_in_reason
      { web: _('To manage a document'),
        email: _('Then you can manage the document.'),
        email_subject: _('Sign in to manage a document') }
    end

    def find_document
      @document = Document.find_public!(params[:id])
      @info_request = @document.info_request
    end

    def require_ability(action, subject = @document)
      raise ActiveRecord::RecordNotFound unless can?(action, subject)
    end

    def manager?
      @document && can?(:manage_document, @document)
    end

    def send_document_file(data = nil, filename:, content_type:, path: nil)
      type = content_type.presence || 'application/octet-stream'
      send_file_content(data, path: path, filename: filename,
                              content_type: type,
                              csp: FileDelivery::DOCUMENT_CSP)
    end

    def send_attachment_file(document)
      attachment = document.foi_attachment
      raise ActiveRecord::RecordNotFound unless attachment&.file&.attached?

      path = Blobs.local_path(attachment.file)
      send_document_file(path ? nil : attachment.file.download,
                         path: path,
                         filename: document.download_filename,
                         content_type: attachment.content_type)
    end

    def send_png(attachment)
      raise ActiveRecord::RecordNotFound unless attachment&.attached?

      path = Blobs.local_path(attachment)
      send_png_content(path ? nil : attachment.download,
                       path: path, url_based_filename: true)
    end

    def page_number
      Integer(params[:page], exception: false) ||
        raise(ActiveRecord::RecordNotFound)
    end

    def redirect_with(path, notice: nil, error: nil)
      flash[:notice] = notice if notice
      flash[:error] = error if error
      redirect_to path
    end
  end
end
