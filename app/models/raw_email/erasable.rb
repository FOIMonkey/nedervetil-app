# Handles the erasure of RawEmail records.
module RawEmail::Erasable
  extend ActiveSupport::Concern

  class ErasedError < StandardError; end

  included do
    delegate :all_attachments_masked_or_erased?, to: :incoming_message
  end

  def erased?
    !file.attached? && erased_at.present?
  end

  def ensure_not_erased!
    raise ErasedError, "email has been erased (ID=#{id})" if erased? || expired?
  end

  def erasable?
    all_attachments_masked_or_erased?
  end

  def failed_parts
    incoming_message.foi_attachments.not_erased.
      where.not(masking_failed_at: nil)
  end

  def erase(editor:, reason:)
    return if erased?

    raise RawEmail::UnmaskedAttachmentsError unless erasable?

    rolled_back = false
    result = transaction do |t|
      t.after_rollback { rolled_back = true }

      failed_parts.find_each do |part|
        part.erase_own_copy!(editor: editor, reason: 'RawEmail#erase')
      end

      raise ActiveRecord::Rollback unless
        log_event(
          'erase_raw_email',
          editor: editor,
          reason: reason,
          raw_email: self,
          storage_key: storage_key
        )

      file.purge_later
      inbound_email&.destroy
      touch(:erased_at)

      expire(preserve_database_cache: true, preserve_attachment_masks: true)

      true
    end
    rolled_back ? false : result
  rescue StandardError
    raise unless rolled_back

    false
  end
end
