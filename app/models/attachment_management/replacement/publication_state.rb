module AttachmentManagement
  class Replacement
    # Settles attachment/document visibility after Replacement writes new bytes:
    # queues requester edits for review, publishes, or rechecks public files.
    class PublicationState
      PublicCopy = Data.define(:bytes, :format, :mask_set, :rules, :maskable)

      attr_reader :attachment, :revision, :editor

      def initialize(attachment, revision:, editor:)
        @attachment = attachment
        @revision = revision
        @editor = editor
        @demoted_from_public = false
      end

      def demoted_from_public?
        @demoted_from_public
      end

      # Demote in the same transaction as the byte swap to prevent exposure.
      def demote_on_apply?(was_public:, publish:)
        return false unless was_public
        return true unless requester_edit?

        publish || requester_review_required?(attachment.disclosure_document)
      end

      def settle!(publish:, was_public:, premask:)
        document = attachment.disclosure_document
        record_new_format!(document) if document
        if requester_edit?
          if requester_review_required?(document)
            demote_to_private!(document)
            document&.log!('review_requested', user: editor)
          elsif publish
            publish_straight_away!(document)
          end
        elsif was_public
          recheck_public_replacement!(document, premask)
        end
      end

      private

      def requester_edit?
        revision.instructions['by_requester'] == true
      end

      def requester_review_required?(document)
        return true if Disclosures.review_requester_redactions?
        return true if revision.instructions['blue_rule_matched'] == true

        document.present? && Disclosures::ReviewSubmission.required?(document)
      end

      def record_new_format!(document)
        new_format = Disclosures::Formats.declared(attachment.content_type,
                                                   attachment.filename)
        return if document.format == new_format

        document.update_columns(format: new_format, updated_at: Time.current)
      end

      def recheck_public_replacement!(document, premask)
        if mask_and_check_for_public!(document, premask)
          attachment.make_public!
        else
          demote_from_public!(document)
        end
      rescue AlaveteliTextMasker::PDFMaskingError, Regexp::TimeoutError,
             Disclosures::RuleCheck::Unreadable
        demote_from_public!(document)
      end

      def mask_and_check_for_public!(document, premask)
        return false if attachment.masking_failed? || premask.failed

        copy = read_public_copy(document)
        if copy.maskable && !premask.masked
          bytes = apply_public_masks_for_replacement(copy.bytes, copy.mask_set)
          return false if bytes.nil?

          copy = copy.with(bytes: bytes)
        end
        return false if rule_words_left?(copy, document)

        document.nil? || rebuild_clean_pages!(document, copy)
      end

      def read_public_copy(document)
        bytes = attachment.file.attached? ? attachment.file.download : ''
        format = Disclosures::Formats.for(attachment.content_type,
                                          attachment.filename, bytes)
        raster = attachment.rasterized?
        mask_set = Masks.public_set(attachment, document)
        PublicCopy.new(
          bytes: bytes,
          format: format,
          mask_set: mask_set,
          rules: mask_set.censor_rules,
          maskable: Disclosures::RuleRemask::MASKABLE.include?(format) &&
                    !raster
        )
      end

      def apply_public_masks_for_replacement(bytes, mask_set)
        return bytes if mask_set.none? || bytes.blank?

        masked, black_matched, unmasked = Masks.apply(
          bytes, mask_set,
          content_type: attachment.content_type,
          filename: attachment.filename
        )
        return nil if unmasked.any?

        if masked != bytes.b
          attachment.replace_file!(masked)
          bytes = masked
        end
        if black_matched && !attachment.black_masked?
          attachment.update_columns(black_masked: true,
                                    updated_at: Time.current)
        end
        bytes
      end

      # Fail closed for unreadable ('other') formats when rules exist.
      def rule_words_left?(copy, document)
        return false unless copy.rules.any?
        return true if copy.format == 'other'
        return false unless copy.maskable || copy.format != 'image'

        Disclosures::RuleCheck.found?(document || attachment, copy.bytes,
                                      format: copy.format, rules: copy.rules)
      end

      def rebuild_clean_pages!(document, copy)
        document.rebuild_pages_from_attachment! &&
          public_pages_clean?(document, copy.rules, maskable: copy.maskable)
      end

      def public_pages_clean?(document, rules, maskable:)
        notes = document.render_notes || {}
        return false if notes['rule_matches']
        if rules.any? && document.pages.any? { |p|
             Disclosures::RuleCheck.matched?(rules, p.text.to_s)
           }
          return false
        end
        return true if maskable

        Array(notes['always_removed_pages']).empty? &&
          Array(notes['masked_pages']).empty?
      end

      def demote_from_public!(document)
        @demoted_from_public = true
        demote_to_private!(document)
      end

      def demote_to_private!(document)
        now = Time.current
        attachment.make_requester_only!(at: now)
        return unless document

        document.purge_public_pages!
        return unless document.published?

        document.update_columns(state: 'draft',
                                withdrawn_at: nil,
                                withdrawn_by_id: nil,
                                withdrawal_kind: nil,
                                withdrawal_reason: nil,
                                updated_at: now)
      end

      def publish_straight_away!(document)
        if document
          Disclosures::Publication.new(document, user: editor).publish!
        else
          attachment.make_public!
        end
      rescue Disclosures::Error::NeedsAdmin => e
        demote_to_private!(document)
        document.log!('review_requested', user: editor, reason: e.message)
      end
    end
  end
end
