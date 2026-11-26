module Disclosures
  # Deletes a request, its replies, private files, and sealed emails while
  # detaching public FoiAttachments so published documents remain live.
  class RequestDeletion
    attr_reader :info_request, :user

    def initialize(info_request, user)
      @info_request = info_request
      @user = user
    end

    def offered?
      return false unless info_request&.persisted?

      ability.can?(:delete_request, info_request)
    end

    def documents
      Document.where(info_request_id: info_request.id).order(:id)
    end

    def readable?(document)
      !Ability::RequesterVisible.hidden_by_admin?(document)
    end

    def blockers
      found = []
      hidden = admin_hidden_content?
      drafts = AttachmentManagement::Revision.open.
        where(foi_attachment_id: request_attachments.select(:id)).
        includes(foi_attachment: { incoming_message: :info_request })
      drafts.group_by(&:foi_attachment).each do |attachment, revisions|
        if hidden_by_admin?(attachment)
          hidden = true
        elsif revisions.any? { ability.can?(:view_attachment_draft, _1) }
          found << _('Save or discard your changes to {{filename}} first.',
                     filename: attachment.display_filename)
        end
      end
      if hidden
        found << _('Part of this request was hidden by an admin. ' \
                   'Ask the site’s admins to delete it.')
      end
      found
    end

    def delete!
      ActiveRecord::Base.transaction do
        info_request.lock!
        IncomingMessage.where(info_request_id: info_request.id).
          order(:id).lock.pluck(:id)
        OutgoingMessage.where(info_request_id: info_request.id).
          order(:id).lock.pluck(:id)
        request_attachments.order(:id).lock.pluck(:id)
        locked = documents.includes(:foi_attachment).lock.to_a
        unless offered?
          raise Error::Refused, _('You can’t delete this request.')
        end

        problems = blockers
        raise Error::Refused, problems.join(' ') if problems.any?

        now = Time.current
        kept = []
        locked.each do |document|
          if document.listed?
            kept << detach_public!(document, now)
          else
            document.purge_public_pages!
            document.destroy!
          end
        end
        info_request.destroy!
        kept
      end
    end

    private

    def ability
      @ability ||= Ability.new(user)
    end

    def admin_hidden_content?
      return true if hidden_by_admin?(info_request)

      IncomingMessage.where(info_request_id: info_request.id).
        includes(:info_request).any? { |m| hidden_by_admin?(m) } ||
        OutgoingMessage.where(info_request_id: info_request.id).
          includes(:info_request).any? { |m| hidden_by_admin?(m) } ||
        request_attachments.includes(incoming_message: :info_request).
          any? { |a| hidden_by_admin?(a) } ||
        documents.includes(foi_attachment: { incoming_message: :info_request }).
          any? { |d| !readable?(d) }
    end

    def hidden_by_admin?(record)
      Ability::RequesterVisible.hidden_by_admin?(record)
    end

    def request_attachments
      FoiAttachment.joins(:incoming_message).
        where(incoming_messages: { info_request_id: info_request.id })
    end

    def detach_public!(document, now)
      attachment = document.foi_attachment
      # Clear open working copies on the detached attachment before removing
      # the request; its applied revisions remain attached to the file.
      AttachmentManagement::Revision.open.
        where(foi_attachment_id: attachment.id).
        find_each { _1.leave!('discarded') }
      AttachmentManagement::Previews.clear(attachment.id)

      attachment.update_columns(incoming_message_id: nil, updated_at: now)
      document.update_columns(
        owner_id: info_request.user_id,
        public_body_id: info_request.public_body_id,
        request_deleted_at: now,
        info_request_id: nil,
        incoming_message_id: nil,
        info_request_batch_id: nil,
        updated_at: now
      )
      document.log!('request_deleted', user: user, public: true)
      document.reload
    end
  end
end
