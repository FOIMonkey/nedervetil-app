class Ability
  # Action abilities on Disclosures::Document and source attachments. Only
  # admins can alter files in ways that add or reveal content, or modify
  # published documents after their request is deleted.
  module DocumentRules
    private

    def document_rules
      can :manage_document, Disclosures::Document do |document|
        document_requester?(document) || document_admin?(document)
      end
      can :edit_document, Disclosures::Document do |document|
        !document.stage_in?(*ERASURE) &&
          (document_admin_change?(document) ||
           (Disclosures.requester_editing? && document_requester?(document) &&
            document.stage_in?(*UNPUBLISHED) &&
            !document.request_deleted? && !with_admin?(document)))
      end
      can :redact_document, Disclosures::Document do |document|
        !document.stage_in?(*ERASURE) &&
          (document_admin_change?(document) ||
           (Disclosures.requester_editing? && document_requester?(document) &&
            !document.foi_attachment&.black_masked? &&
            !document.request_deleted? && !with_admin?(document)))
      end
      can :change_document_file, Disclosures::Document do |document|
        !document.stage_in?(*ERASURE) && document_admin_change?(document)
      end
      can :publish_document, Disclosures::Document do |document|
        !document.stage_in?(*ERASURE) && document_admin_change?(document)
      end
      # Withdrawn or taken-down documents stay down for the requester.
      can :publish_own_document, Disclosures::Document do |document|
        Disclosures.requester_editing? && incoming_document_source?(document) &&
          document.stage_in?(*OWN_PUBLISHING) &&
          !document.request_deleted? && document_requester?(document)
      end
      can :publish_from_reply, IncomingMessage do |message|
        publish_from_reply?(message)
      end
      can :review_documents, Disclosures::Document if admin?
      # A banned requester can still withdraw: it only ever hides.
      can :withdraw_document, Disclosures::Document do |document|
        document.stage_in?(*PUBLISHED) &&
          (can?(:manage_document, document) ||
           document_requester?(document, active: false))
      end
      can :delete_document, Disclosures::Document do |document|
        !document.stage_in?(*ERASURE) && !document.ever_published? &&
          (document_admin?(document) ||
           (Disclosures.requester_editing? &&
            document_requester?(document, active: false) &&
            !with_admin?(document)))
      end
      can :mark_publication_unwanted, Disclosures::Document do |document|
        may_withdraw_or_delete? && document.requester_id == user.id &&
          Disclosures::ReviewSubmission.pending?(document) &&
          !Disclosures::ReviewSubmission.unwanted(document)
      end
      can :erase_document, Disclosures::Document do |document|
        !document.stage_in?(*ERASURE) && document_admin?(document)
      end

      can :create_document, FoiAttachment do |attachment|
        create_document?(attachment)
      end
      can :request_document_review, FoiAttachment do |attachment|
        !Disclosures.requester_editing? &&
          document_source_access?(attachment) &&
          attachment.info_request.is_actual_owning_user?(user)
      end
      can :see_document_panel, InfoRequest do |info_request|
        document_panel?(info_request)
      end
    end

    def incoming_document_source?(document)
      message = document.incoming_message
      attachment = document.foi_attachment
      message && attachment &&
        message.info_request_id == document.info_request_id &&
        attachment.incoming_message_id == message.id
    end

    # Pending review or admin takedown locks the document from requester edits
    # or deletion; self-withdrawn documents remain the requester's.
    def with_admin?(document)
      (document.withdrawn? &&
        document.withdrawn_by_id != document.requester_id) ||
        Disclosures::ReviewSubmission.pending?(document)
    end

    def document_admin_change?(document)
      document_admin?(document) &&
        (!document.request_deleted? || document.ever_published?)
    end

    def create_document?(attachment)
      return false unless document_source_access?(attachment)

      can?(:admin, attachment.info_request) || Disclosures.requester_editing?
    end

    def document_source_access?(attachment)
      return false unless may_act?
      return false if attachment.erased? || attachment.masking_failed? ||
                      attachment.incoming_message.nil?

      request = attachment.info_request
      return false unless request && can?(:read, attachment)

      can?(:admin, request) || request.is_actual_owning_user?(user)
    end

    def publish_from_reply?(message)
      return false unless Disclosures.requester_editing? && may_act?

      request = message.info_request
      document_panel?(request) && request.is_actual_owning_user?(user) &&
        can?(:read, message)
    end

    # Excludes the holding pen without creating/mutating it on a page view.
    def document_panel?(info_request)
      return false unless user && info_request
      return false if info_request.holding_pen_request?(read_only: true)
      return false unless can?(:read, info_request)

      can?(:admin, info_request) || info_request.is_actual_owning_user?(user)
    end
  end
end
