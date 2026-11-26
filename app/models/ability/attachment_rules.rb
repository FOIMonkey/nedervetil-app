class Ability
  # Attachment management abilities. :replace_attachment covers actions that
  # can add, swap or reveal content (uploads, free text edits, or Office
  # conversion, where LibreOffice can expose hidden content like tracked
  # deletions).
  module AttachmentRules
    private

    def attachment_rules
      can :manage_attachment, FoiAttachment do |attachment|
        manage_attachment?(attachment)
      end
      can :replace_attachment, FoiAttachment do |attachment|
        can?(:manage_attachment, attachment) &&
          (can?(:admin, attachment.info_request) ||
           AttachmentManagement.requester_access == 'replace')
      end
      can :edit_attachment_text, FoiAttachment do |attachment|
        can?(:admin, attachment.info_request) || Disclosures.requester_editing?
      end
      can :view_attachment_draft, AttachmentManagement::Revision do |revision|
        can?(:manage_attachment, revision.foi_attachment) &&
          (revision.user_id == user.id ||
           can?(:admin, revision.foi_attachment.info_request))
      end
    end

    def manage_attachment?(attachment)
      return false unless may_act?
      return false if attachment.erased? || attachment.incoming_message.nil?

      info_request = attachment.info_request
      return false unless info_request && can?(:read, attachment)

      can?(:admin, info_request) ||
        (AttachmentManagement.requester_access != 'none' &&
         !attachment.black_masked? &&
         info_request.is_actual_owning_user?(user))
    end
  end
end
