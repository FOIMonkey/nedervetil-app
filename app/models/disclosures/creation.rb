module Disclosures
  # Creates a slim Document row pointing directly at an existing FoiAttachment.
  class Creation
    attr_reader :user, :attachment, :kind, :source_kind

    def initialize(user:, attachment:, kind:, email_text: false)
      @user = user
      @attachment = attachment
      @kind = kind.to_s
      @source_kind = email_text ? 'email_text' : 'attachment'
    end

    def create!(for_review: false)
      unless KINDS.include?(kind)
        raise Error::Refused, _('Choose decision letter or released records.')
      end

      check_file!
      unless Ability.new(user).can?(:admin, attachment.info_request)
        Limits.documents!(user)
      end

      document = nil
      Document.transaction(requires_new: true) do
        action = for_review ? :request_document_review : :create_document
        unless Ability.new(user).can?(action, attachment.reload)
          raise Error::Refused,
                _('You can’t make a document from this file now.')
        end

        document = Document.create!(attributes)
        document.log!(for_review ? 'review_requested' : 'created',
                      user: user, kind: kind, source: source_kind)
      end
      document
    rescue ActiveRecord::RecordNotUnique
      existing = Document.find_by(foi_attachment_id: attachment.id)
      if existing && Ability.new(user).can?(:manage_document, existing)
        return existing
      end

      raise Error::Refused,
            _('A document has already been made from that file.')
    end

    private

    def check_file!
      message = attachment.incoming_message
      if source_kind == 'email_text'
        unless message&.get_main_body_text_part&.id == attachment.id
          raise Error::Refused, _('That is not a reply’s own text.')
        end
      elsif message.nil? || message.get_main_body_text_part&.id == attachment.id
        raise Error::Refused, _('That is not one of the reply’s attachments.')
      elsif !Formats.supported?(attachment.content_type,
                                attachment.display_filename)
        raise Error::Refused, _(Formats::REFUSED)
      end
    end

    def attributes
      request = attachment.info_request
      {
        info_request: request,
        public_body: request.public_body,
        incoming_message: attachment.incoming_message,
        foi_attachment: attachment,
        info_request_batch_id: request.info_request_batch_id,
        source_kind: source_kind,
        kind: kind,
        format: Formats.declared(attachment.content_type, attachment.filename),
        title: Titles.suggest(kind, request, released_on),
        released_on: released_on,
        document_date: kind == 'decision_letter' ? released_on : nil,
        created_by: user,
        updated_by: user
      }
    end

    def released_on
      @released_on ||= attachment.incoming_message.sent_at&.to_date ||
                       Date.current
    end
  end
end
