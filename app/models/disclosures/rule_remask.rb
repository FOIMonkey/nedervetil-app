module Disclosures
  # Applies a saved censor rule in place on FoiAttachment#file blobs.
  module RuleRemask
    MASKABLE = %w[pdf text csv].freeze

    module_function

    def apply_to_attachment!(attachment, rule)
      return :skipped if attachment.erased? || !attachment.file.attached?

      unless attachment.is_public?
        return :skipped unless rule.black?

        FoiAttachment::MaskJob.unlock!(attachment)
        FoiAttachment::MaskJob.perform_now(attachment)
        return :masked
      end

      apply_to_public!(attachment, rule)
    end

    def remask_after_removal!(attachment)
      return false if attachment.erased? || attachment.is_public?
      return false unless attachment.black_masked?
      return false if attachment.manual_black_mask?

      attachment.remask_from_email!
    end

    def apply_to_public!(attachment, rule)
      document = attachment.disclosure_document
      bytes = attachment.file.download
      format = Formats.for(attachment.content_type, attachment.filename, bytes)
      raster = raster_pdf?(attachment, document)

      details_hit = document && details_match?(document, [rule])
      file_hit = if raster
                   raster_match?(attachment, document, [rule])
                 else
                   file_match?(attachment, document, bytes, format, [rule])
                 end
      return :unchanged unless details_hit || file_hit

      hide_for_remask!(attachment, document)

      if file_hit && MASKABLE.include?(format) && !raster
        remask_public_file!(attachment, document, bytes, rule,
                            details_hit: details_hit)
      else
        leave_private_without_masking!(attachment, rule,
                                       file_hit: file_hit, raster: raster)
      end
    end

    def leave_private_without_masking!(attachment, rule, file_hit:, raster:)
      if rule.black? && file_hit
        if raster
          hide_unmaskable_black_match!(attachment)
        else
          FoiAttachment::MaskJob.unlock!(attachment)
          FoiAttachment::MaskJob.perform_now(attachment)
        end
      end
      :left_private
    end

    def remask_public_file!(attachment, document, bytes, rule, details_hit:)
      problem = remask_problem!(attachment, document, bytes, rule,
                                details_hit: details_hit)
      return leave_private!(attachment, document, rule, problem) if problem

      restore_public!(attachment, document)
      :republished
    rescue AlaveteliTextMasker::PDFMaskingError, Regexp::TimeoutError
      leave_private!(attachment, document, rule, :masking_failed)
    end

    def remask_problem!(attachment, document, bytes, rule, details_hit:)
      masked_bytes = mask_with_rule(attachment, bytes, rule)
      return :masking_failed unless masked_bytes

      bytes_changed = masked_bytes != bytes.b
      store_masking!(attachment, masked_bytes, rule,
                     bytes_changed: bytes_changed)
      format = Formats.for(attachment.content_type, attachment.filename,
                           masked_bytes)
      if RuleCheck.found?(document || attachment, masked_bytes,
                          format: format, rules: [rule])
        return :words_remain
      end

      unchanged_pdf = !bytes_changed && format == 'pdf'
      unless rebuild_clean_pages!(attachment, document, rule,
                                  unchanged_pdf: unchanged_pdf)
        return :pages_not_clean
      end

      :details_match if details_hit
    end

    # Returns masked bytes, or nil if non-zip parts could not be masked.
    def mask_with_rule(attachment, bytes, rule)
      unmasked = []
      masked = Masking.apply_rules(
        bytes,
        content_type: attachment.content_type,
        filename: attachment.filename,
        rules: [rule],
        unmasked: unmasked
      )
      unmasked -= [AlaveteliTextMasker::UNMASKED_ZIP]
      return if unmasked.any?

      masked.b
    end

    def store_masking!(attachment, masked_bytes, rule, bytes_changed:)
      if bytes_changed
        attachment.replace_file!(masked_bytes)
        attrs = { masked_at: Time.zone.now, masking_failed_at: nil }
        attrs[:black_masked] = true if rule.black?
        attachment.update!(attrs)
      elsif rule.black? && !attachment.black_masked?
        attachment.update!(black_masked: true)
      end
    end

    def rebuild_clean_pages!(attachment, document, rule, unchanged_pdf:)
      return true unless document

      document.association(:foi_attachment).target = attachment
      document.pages.reset
      rebuilt = document.rebuild_pages_from_attachment!
      clean = clean_rebuilt_document?(document, [rule],
                                      unchanged_pdf: unchanged_pdf)
      rebuilt && clean
    end

    # Black rules hide the file from the requester too, unless only document
    # metadata (:details_match) matched.
    def leave_private!(attachment, document, rule, problem)
      case problem
      when :masking_failed
        record_black_fault(attachment) if rule.black?
      when :words_remain
        hide_unmaskable_black_match!(attachment) if rule.black?
      when :pages_not_clean
        document&.purge_public_pages!
        hide_unmaskable_black_match!(attachment) if rule.black?
      when :details_match
        document&.purge_public_pages!
      end
      :left_private
    end

    def clean_rebuilt_document?(document, rules, unchanged_pdf: false)
      notes = document.render_notes || {}
      return false if notes['rule_matches']
      return false if Array(notes['always_removed_pages']).any?

      document.pages.reset
      return false if unchanged_pdf && unverified_pdf_pages?(document, notes)

      !page_text_match?(document, rules)
    end

    def unverified_pdf_pages?(document, notes)
      Array(notes['ocr_skipped']).any? ||
        Array(notes['unread_pages']).any? ||
        Array(notes['unread_flagged']).any? ||
        document.pages.any? { |page| page.text_source == 'none' }
    end

    def hide_for_remask!(attachment, document)
      attachment.make_requester_only!
      return unless document&.published?

      document.withdraw!(
        kind: 'source_changed',
        reason: 'Taken down for a site privacy check. An admin will review ' \
                'it before it can be shared again.'
      )
      document.purge_public_pages!
    end

    def restore_public!(attachment, document)
      now = Time.current
      attachment.make_public!(at: now)
      return unless document

      document.update_columns(
        state: 'published',
        withdrawn_at: nil,
        withdrawn_by_id: nil,
        withdrawal_kind: nil,
        withdrawal_reason: nil,
        updated_at: now
      )
    end

    def details_match?(document, rules)
      fields = [document.title, document.description].compact
      fields.any? { |value| RuleCheck.matched?(rules, value.to_s) }
    rescue RuleCheck::Unreadable => e
      Rails.logger.warn('rule_remask_details_unreadable ' \
                        "document_id=#{document.id} #{e.class}")
      true
    end

    def file_match?(attachment, document, bytes, format, rules)
      return true if page_text_match?(document, rules)

      RuleCheck.match?(document || attachment, bytes,
                       rules: rules, format: format)
    rescue RuleCheck::Unreadable
      true
    end

    def raster_match?(attachment, document, rules)
      return true if page_text_match?(document, rules)
      return false unless attachment.raw_email&.kept?

      raw_bytes = attachment.unmasked_body
      return false if raw_bytes.blank?

      format = Formats.for(attachment.content_type, attachment.filename,
                           raw_bytes)
      RuleCheck.match?(document || attachment, raw_bytes.b,
                       rules: rules, format: format)
    rescue RuleCheck::Unreadable, RawEmail::Erasable::ErasedError,
           FoiAttachment::MissingError, ActiveStorage::FileNotFoundError
      false
    end

    def page_text_match?(document, rules)
      return false unless document

      document.pages.any? { |page| RuleCheck.matched?(rules, page.text.to_s) }
    rescue RuleCheck::Unreadable
      true
    end

    def raster_pdf?(attachment, _document)
      attachment.rasterized?
    end

    def hide_unmaskable_black_match!(attachment)
      attachment.hide_for_black_rule!(
        reason: 'A masking rule matched this file.'
      )
    end

    def record_black_fault(attachment)
      attachment.hide_for_black_rule!(
        reason: 'A masking rule failed on this file.'
      )
    end

    private_class_method :leave_private_without_masking!, :remask_problem!,
                         :mask_with_rule, :store_masking!,
                         :rebuild_clean_pages!, :leave_private!
  end
end
