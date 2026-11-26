# Handles the erasure of FoiAttachment records.
module FoiAttachment::Erasable
  extend ActiveSupport::Concern

  ErasedError = Class.new(StandardError)

  included do
    scope :erased, -> { where.not(erased_at: nil) }
    scope :not_erased, -> { where(erased_at: nil) }

    delegate :erased?, :ensure_not_erased!, to: :raw_email, prefix: :raw_email
  end

  def erased?
    erased_at.present?
  end

  def ensure_not_erased!
    raise ErasedError, "attachment has been erased (ID=#{id})" if erased?
  end

  def erase_later(editor:, reason:)
    FoiAttachment::EraseJob.perform_later(self, editor: editor, reason: reason)
  end

  def erase(editor:, reason:)
    return if erased?

    mask_siblings

    # Use a flag instead of returning inside after_rollback, which would skip
    # subsequent rollback hooks and raise LocalJumpError.
    rolled_back = false
    result = transaction do |t|
      t.after_rollback { rolled_back = true }

      erase_own_copy!(editor: editor, reason: reason)

      # Nested RawEmail#erase rollback only returns falsy; propagate rollback
      # so the attachment is never erased while its raw email remains.
      raise ActiveRecord::Rollback unless
        raw_email.erased? ||
        raw_email.erase(editor: editor, reason: 'FoiAttachment#erase')

      expire(preserve_attachment_masks: true)

      true
    end
    rolled_back ? false : result
  rescue StandardError
    # Return false if an error occurred after rolling back the erasure.
    raise unless rolled_back

    false
  end

  # Erases this attachment within the caller's transaction; also called by
  # RawEmail#erase for failed_parts.
  def erase_own_copy!(editor:, reason:)
    raise ActiveRecord::Rollback unless
      log_event(
        'erase_attachment',
        editor: editor,
        reason: reason,
        attachment: self,
        storage_key: storage_key
      )

    self.filename = nil
    ensure_filename!

    self.erased_at = Time.zone.now
    save!

    delete_cached_file!
    if (document = disclosure_document) && !document.erased?
      document.purge_public_pages!
      document.update_columns(state: 'withdrawn',
                              withdrawal_kind: 'erased',
                              erased_at: Time.current,
                              updated_at: Time.current)
    end
    incoming_message&.clear_in_database_caches! if main_body_part?
  end
end
