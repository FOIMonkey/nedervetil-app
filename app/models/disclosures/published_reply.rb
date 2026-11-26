module Disclosures
  # The published step: what from one reply is public now, with an admin, or
  # withdrawn.
  class PublishedReply
    attr_reader :documents

    def initialize(documents)
      @documents = documents
    end

    # Public documents with no changes waiting for admin review.
    def listed
      @listed ||= documents.all.select { _1.stage_in?(:listed) } - waiting
    end

    def waiting
      @waiting ||= documents.all.select do |document|
        ReviewSubmission.pending?(document)
      end
    end

    # Withdrawn stays down for the requester, so the page doesn't offer it.
    def withdrawn
      @withdrawn ||= Document.where(
        incoming_message_id: documents.message.id,
        info_request_id: documents.info_request.id
      ).select do |document|
        document.stage_in?(:erased, :erasing, :withdrawn, :taken_down) &&
          documents.ability.can?(:manage_document, document)
      end
    end

    def title
      if listed.any?
        _('Now public')
      elsif waiting.any?
        _('Waiting for admin review')
      elsif withdrawn.any?
        _('Withdrawn')
      else
        _('Nothing public yet')
      end
    end
  end
end
