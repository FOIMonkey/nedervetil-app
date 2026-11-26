module Disclosures
  # A request's documents by attachment, read once per page instead of once
  # per file.
  class AttachmentDocuments
    def initialize(info_request_id)
      @ids = FoiAttachment.joins(:incoming_message).
        where(incoming_messages: { info_request_id: info_request_id }).
        pluck(:id).to_set
      @documents = if @ids.empty?
                     {}
                   else
                     Document.where(foi_attachment_id: @ids.to_a).
                       includes(:events).
                       index_by(&:foi_attachment_id)
                   end
    end

    def documents
      @documents.values
    end

    def for(attachment_id)
      if @ids.include?(attachment_id)
        @documents[attachment_id]
      else
        Document.find_by(foi_attachment_id: attachment_id)
      end
    end
  end
end
