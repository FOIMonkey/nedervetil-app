module Disclosures
  # Publishes, withdraws, and erases one-file disclosure documents.
  class Publication
    DELETED = 'Its request was deleted before it was ever published, so ' \
              'it can’t be published.'.freeze

    attr_reader :document, :user

    def initialize(document, user:)
      @document = document
      @user = user
    end

    # Runs under the document lock in a nested transaction; on rollback,
    # uploaded blobs from this attempt are deleted.
    def publish!(**)
      created_blobs = []
      attachment = nil
      converted_request_id = nil

      document.with_lock do
        document.transaction(requires_new: true) do
          # Capture locals lazily so hooks see values set by later stages.
          tx = document.class.connection.current_transaction
          tx.after_rollback { undo_failed_attempt(created_blobs, attachment) }
          tx.after_commit { purge_regulator_packs(converted_request_id) }

          refuse_if_deleted_before_published!
          attachment = document.foi_attachment
          refuse_unless_file_ready!(attachment)
          ensure_source_visible!(attachment) unless document.request_deleted?
          if convert_legacy_doc!(attachment, created_blobs)
            converted_request_id = attachment.info_request&.id
          end
          apply_public_masks!(attachment, created_blobs)
          render_document!(created_blobs)
          enforce_requester_safety!(attachment) unless admin_publisher?
          record_published!(attachment)
        end
      end
    end

    def withdraw!(reason:)
      if reason.to_s.strip.empty?
        raise Error::Refused, _('Say why it is being withdrawn.')
      end

      document.with_lock do
        unless document.stage_in?(:listed, :unlisted)
          raise Error::Refused, _('This document is not published.')
        end

        if document.foi_attachment&.is_public?
          document.foi_attachment.make_requester_only!
        end
        document.withdraw!(kind: 'manual',
                           reason: reason.to_s.strip.truncate(500),
                           by: user)
        document.purge_public_pages!
        document.log!('withdrawn', user: user)
      end
    end

    def erase!(reason: nil)
      document.with_lock do
        return false if document.stage_in?(:erasing, :erased)

        now = Time.current
        document.withdraw!(kind: 'erased', reason: reason, by: user)
        document.update_columns(erased_at: now, updated_at: now)
        document.purge_public_pages!

        attachment = document.foi_attachment
        if attachment
          if attachment.incoming_message_id.nil?
            attachment.file.purge if attachment.file.attached?
            attachment.hide_as_erased!(at: now)
          elsif attachment.is_public?
            attachment.make_requester_only!(at: now)
          end
        end
        document.log!('erased', user: user)
        true
      end
    end

    private

    def refuse_if_deleted_before_published!
      return unless document.request_deleted? && !document.ever_published?

      raise Error::Refused, DELETED
    end

    def refuse_unless_file_ready!(attachment)
      unless attachment && !attachment.erased? &&
             !attachment.masking_failed? && attachment.file.attached?
        raise Error::Refused, _('There is no file ready to publish.')
      end
    end

    def ensure_source_visible!(attachment)
      message = attachment.incoming_message
      request = message&.info_request
      if message.nil? || request.nil? ||
         Ability::RequesterVisible.own(message) != :requester ||
         !Ability::RequesterVisible.requester?(request)
        raise Error::Refused,
              _('The reply or request is hidden, so it can’t be published.')
      end
    end

    def admin_publisher?
      user.present? && Ability.new(user).can?(:publish_document, document)
    end

    def enforce_requester_safety!(attachment)
      reason = requester_safety_block(attachment) or return

      document.purge_public_pages!
      attachment.make_requester_only!
      raise Error::NeedsAdmin, reason
    end

    def requester_safety_block(attachment)
      notes = document.render_notes || {}
      if Array(notes['always_removed_pages']).any?
        return _('This file contains a sign-in link or request reply address ' \
                 'that can’t be published automatically. An admin needs to ' \
                 'check it first.')
      end
      if notes['rule_matches']
        return _('This file needs a site privacy check before it can be ' \
                 'shared. An admin needs to check it first.')
      end
      if Array(notes['risky_hidden']).any?
        return _('This file has hidden content that needs an admin’s check ' \
                 'before it can go public.')
      end
      return unless check_masked_pages?(attachment)
      return unless Array(notes['masked_pages']).any?

      _('This file contains personal details that couldn’t be masked ' \
        'automatically. An admin needs to check it first.')
    end

    def check_masked_pages?(attachment)
      !RuleRemask::MASKABLE.include?(document.format) ||
        attachment.rasterized? ||
        document.pages.any? { |page| page.text_source == 'ocr' } ||
        (document.render_notes || {})['ocr_flagged'].present?
    end

    def convert_legacy_doc!(attachment, created_blobs)
      return false unless Formats.legacy_doc?(attachment.content_type,
                                              attachment.filename)

      bytes = attachment.file.download
      raise Error::Refused, _(Formats::REFUSED) unless Formats.ole2?(bytes)

      source_type = attachment.content_type
      source_filename = attachment.filename
      extension = Formats.safe_extension(source_filename, source_type)
      pdf_bytes = LegacyOffice.to_pdf(bytes, extension: extension)
      pdf_filename = pdf_filename_for(attachment)

      existing = (attachment.file_blob&.metadata || {}).
                 except('identified', 'analyzed')
      metadata = Formats.record_conversion(
        existing,
        from_content_type: source_type,
        from_filename: source_filename,
        to_content_type: 'application/pdf',
        to_filename: pdf_filename
      )

      before_blob = attachment.file_blob
      attachment.content_type = 'application/pdf'
      attachment.filename = pdf_filename
      attachment.masked_at ||= Time.zone.now
      begin
        attachment.replace_file!(pdf_bytes, content_type: 'application/pdf',
                                            metadata: metadata)
      ensure
        after_blob = attachment.file_blob
        created_blobs << after_blob if after_blob && after_blob != before_blob
      end
      document.update!(format: 'pdf')
      true
    end

    def apply_public_masks!(attachment, created_blobs)
      before_blob = attachment.file_blob
      Masking.apply_public_masks!(attachment, document)
    ensure
      after_blob = attachment.file_blob
      created_blobs << after_blob if after_blob && after_blob != before_blob
    end

    def render_document!(created_blobs)
      Renderer.new(document).run
    ensure
      collect_rendered_blobs(created_blobs)
    end

    def collect_rendered_blobs(created_blobs)
      if document.thumbnail.attached? && document.thumbnail.blob
        created_blobs << document.thumbnail.blob
      end
      document.pages.each do |page|
        next unless page.image.attached? && page.image.blob

        created_blobs << page.image.blob
      end
    end

    def record_published!(attachment)
      now = Time.current
      attachment.make_public!(at: now)
      document.update!(
        state: 'published',
        public_body_id: document.authority&.id || document.public_body_id,
        published_at: now,
        published_by: user,
        first_published_at: document.first_published_at || now,
        updated_by: user,
        withdrawn_at: nil,
        withdrawn_by: nil,
        withdrawal_kind: nil,
        withdrawal_reason: nil
      )
      TopicMatch.record(document)
      document.log!('published', user: user)
    end

    def pdf_filename_for(attachment)
      base = attachment.redacted_filename.sub(/\.[A-Za-z0-9]{1,5}\z/, '')
      "#{base}.pdf"
    end

    def undo_failed_attempt(created_blobs, attachment)
      cleanup_uploaded_blobs(created_blobs)
      reset_after_rollback!(attachment)
    end

    def purge_regulator_packs(converted_request_id)
      return unless converted_request_id

      RegulatorPack.purge_for_request!(converted_request_id)
    end

    def cleanup_uploaded_blobs(blobs)
      blobs.uniq.each do |blob|
        blob.service.delete(blob.key)
      rescue StandardError => e
        Rails.logger.warn('publication_upload_cleanup_failed ' \
                          "document_id=#{document.id} #{e.class}")
        nil
      end
    end

    def reset_after_rollback!(attachment)
      if attachment&.persisted?
        attachment.instance_variable_set(:@cached_body, nil)
        attachment.reload
      end
      document.reload if document.persisted?
    rescue ActiveRecord::RecordNotFound
      nil
    end
  end
end
