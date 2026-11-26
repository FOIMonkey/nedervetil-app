module AttachmentManagement
  # Applies a ready Revision in place onto FoiAttachment#file and purges drafts.
  # Masks bytes before locking, verifies and writes under attachment + revision
  # row locks, then cleans up and delegates visibility to PublicationState.
  class Replacement
    Refused = Class.new(StandardError)
    Stale = Class.new(Refused)

    Identity = Data.define(:content_type, :filename)

    # Black-rule masking outcome (:none, :unmaskable, :applied, or :failed).
    BlackMask = Data.define(:status, :bytes, :black_matched, :fault,
                            :unmasked) do
      def initialize(status:, bytes:, black_matched: false, fault: nil,
                     unmasked: [])
        super
      end
    end

    # Bytes to store and whether pre-lock public masking succeeded or failed.
    PublicMask = Data.define(:bytes, :masked, :failed, :black_matched) do
      def initialize(bytes:, masked: false, failed: false, black_matched: false)
        super
      end
    end

    # Pre-lock masked draft; raw_sha256 verifies stored bytes didn't change.
    Prepared = Data.define(:raw_sha256, :was_public, :black, :premask)

    attr_reader :editor, :reason, :confirmed_sha256, :black_mask_status
    attr_accessor :revision

    def initialize(revision, editor:, reason: nil, confirmed_sha256: nil)
      @revision = revision
      @editor = editor
      @reason = reason.to_s.strip
      @confirmed_sha256 = confirmed_sha256
      @black_mask_status = :none
      @demoted_from_public = false
    end

    def demoted_from_public?
      @demoted_from_public
    end

    def apply!(publish: false)
      attachment = event = nil
      was_public = false
      prepared = prepare_outside_lock

      FoiAttachment.transaction do
        attachment = lock_and_check!(prepared)
        was_public = attachment.is_public?
        demote = publication_state(attachment).
          demote_on_apply?(was_public: was_public, publish: publish)
        apply_bytes!(attachment, prepared, demote_to_requester_only: demote)
        event = record_applied!(attachment)
      end

      @black_mask_status = prepared.black.status
      cleanup_working_copies!(attachment)
      handle_publication_state!(attachment,
                                publish: publish,
                                was_public: was_public,
                                premask: premask_to_trust(prepared, was_public))
      event
    rescue Stale
      revision.leave!('superseded')
      raise
    end

    private

    def prepare_outside_lock
      initial_attachment = FoiAttachment.find(revision.foi_attachment_id)
      initial_revision = Revision.find(revision.id)
      unless precheck_ready?(initial_attachment, initial_revision)
        return empty_preparation
      end

      raw_bytes = initial_revision.output_bytes
      raw_sha256 = Digest::SHA256.hexdigest(raw_bytes)
      if initial_revision.output_sha256.present? &&
         raw_sha256 != initial_revision.output_sha256
        return empty_preparation
      end

      target = target_identity(initial_attachment, initial_revision)
      raster = initial_revision.kind == 'pdf_redaction'
      was_public = initial_attachment.is_public?
      black = best_effort_black_mask(initial_attachment, raw_bytes, target,
                                     raster: raster)
      premask = prepare_public_bytes(initial_attachment, black, target,
                                     was_public: was_public, raster: raster)
      Prepared.new(raw_sha256: raw_sha256, was_public: was_public,
                   black: black, premask: premask)
    end

    def precheck_ready?(attachment, rev)
      return false unless rev.ready? && !attachment.erased? &&
                          rev.output.attached?

      confirmed_sha256.nil? ||
        ActiveSupport::SecurityUtils.secure_compare(
          confirmed_sha256.to_s, rev.output_sha256.to_s
        )
    end

    # Defer refusal reasons to locked checks without masking unready drafts.
    def empty_preparation
      Prepared.new(raw_sha256: nil, was_public: false,
                   black: BlackMask.new(status: :none, bytes: ''),
                   premask: PublicMask.new(bytes: ''))
    end

    def target_identity(attachment, rev)
      Identity.new(
        content_type: rev.output_content_type.presence ||
                      attachment.content_type,
        filename: rev.output_filename.presence || attachment.filename
      )
    end

    def lock_and_check!(prepared)
      attachment = FoiAttachment.lock.find(revision.foi_attachment_id)
      @revision = Revision.lock.find(revision.id)
      check!(attachment)
      check_draft_unchanged!(prepared)
      attachment
    end

    def check!(attachment)
      unless revision.ready?
        raise Refused, _('This draft is not ready to apply.')
      end
      raise Stale, _('This attachment has been erased.') if attachment.erased?
      unless confirmed_sha256.nil? ||
             ActiveSupport::SecurityUtils.secure_compare(
               confirmed_sha256.to_s, revision.output_sha256.to_s
             )
        raise Refused, _('The confirmation is for a different version of ' \
                         'this draft. Review it again.')
      end

      current = attachment.file.attached? ? attachment.file.download : ''
      return if Digest::SHA256.hexdigest(current) == revision.source_sha256

      raise Stale, _('The attachment has changed since this draft was made. ' \
                     'Make a new draft.')
    end

    def check_draft_unchanged!(prepared)
      sha256 = Digest::SHA256.hexdigest(revision.output_bytes)
      recorded = revision.output_sha256
      return if (recorded.blank? || recorded == sha256) &&
                prepared.raw_sha256 == sha256

      raise Refused, _('The stored draft no longer matches what was reviewed.')
    end

    def publication_state(attachment)
      PublicationState.new(attachment, revision: revision, editor: editor)
    end

    # Drop premask if the attachment became public during unlocked masking.
    def premask_to_trust(prepared, was_public)
      premask = prepared.premask
      return premask unless was_public && !prepared.was_public &&
                            !requester_edit?

      premask.with(masked: false)
    end

    def apply_output_identity!(attachment)
      if revision.output_content_type.present?
        attachment.content_type = revision.output_content_type
      end
      if revision.output_filename.present?
        attachment.filename = revision.output_filename
      end
      attachment.ensure_filename!
    end

    def best_effort_black_mask(attachment, bytes, target, raster:)
      black_set = Masks.black_set(attachment, attachment.disclosure_document)
      if black_set.censor_rules.empty? || bytes.blank?
        return BlackMask.new(status: :none, bytes: bytes)
      end

      format = Disclosures::Formats.for(target.content_type, target.filename,
                                        bytes)
      unless Disclosures::RuleRemask::MASKABLE.include?(format) && !raster
        return BlackMask.new(status: :unmaskable, bytes: bytes)
      end

      masked, black_matched, unmasked = Masks.apply(
        bytes, black_set,
        content_type: target.content_type, filename: target.filename
      )
      if unmasked.any?
        return black_mask_failure(attachment, bytes, target,
                                  fault: unmasked.join('; ').truncate(300),
                                  unmasked: unmasked)
      end

      final = if html_file?(target) && masked != bytes.b
                attachment.sanitise_html(masked)
              else
                masked
              end
      BlackMask.new(status: :applied, bytes: final,
                    black_matched: black_matched)
    rescue AlaveteliTextMasker::PDFMaskingError, Regexp::TimeoutError => e
      fault = "#{e.class}: #{e.message.lines.first.to_s.strip}".truncate(300)
      black_mask_failure(attachment, bytes, target, fault: fault, unmasked: [])
    end

    def black_mask_failure(attachment, bytes, target, fault:, unmasked:)
      fallback = if html_file?(target)
                   attachment.sanitise_html(bytes)
                 else
                   bytes
                 end
      BlackMask.new(status: :failed, bytes: fallback, fault: fault,
                    unmasked: unmasked)
    end

    def prepare_public_bytes(attachment, black, target, was_public:, raster:)
      bytes = black.bytes
      unchanged = PublicMask.new(bytes: bytes, failed: black.status == :failed)
      return unchanged if unchanged.failed
      return unchanged unless was_public && !requester_edit?

      bytes = Disclosures::Tidy.apply(bytes, target.content_type,
                                      target.filename)
      unchanged = unchanged.with(bytes: bytes)
      format = Disclosures::Formats.for(target.content_type, target.filename,
                                        bytes)
      return unchanged unless Disclosures::RuleRemask::MASKABLE.include?(format)
      return unchanged if raster

      mask_set = Masks.public_set(attachment, attachment.disclosure_document)
      return unchanged.with(masked: true) if mask_set.none? || bytes.blank?

      masked, black_matched, unmasked = Masks.apply(
        bytes, mask_set,
        content_type: target.content_type, filename: target.filename
      )
      return unchanged.with(failed: true) if unmasked.any?

      PublicMask.new(bytes: masked, masked: true, black_matched: black_matched)
    rescue AlaveteliTextMasker::PDFMaskingError, Regexp::TimeoutError,
           Disclosures::Tidy::Refused
      unchanged.with(failed: true)
    end

    def apply_bytes!(attachment, prepared, demote_to_requester_only:)
      previous = Identity.new(content_type: attachment.content_type,
                              filename: attachment.filename)
      apply_output_identity!(attachment)
      black = prepared.black
      notes = replacement_metadata(attachment, black, previous: previous)
      now = Time.zone.now
      attachment.masked_at = now
      attachment.masking_failed_at = black.status == :failed ? now : nil
      if admin_black_mask? || black.black_matched ||
         prepared.premask.black_matched
        attachment.black_masked = true
      end
      attachment.prominence = 'requester_only' if demote_to_requester_only
      attachment.replace_file!(prepared.premask.bytes,
                               content_type: attachment.content_type,
                               metadata: notes)
    end

    def replacement_metadata(attachment, black, previous:)
      existing = attachment.file_blob&.metadata || {}
      notes = existing.except(*FoiAttachment::Maskable::FAULT_NOTES,
                              'unmasked_parts', 'identified', 'analyzed')
      if revision.kind == 'pdf_redaction'
        notes['rasterized'] = true
      else
        notes.delete('rasterized')
      end
      notes['manual_black_mask'] = true if admin_black_mask?
      note_black_mask_fault(notes, black) if black.status == :failed
      Disclosures::Formats.record_conversion(
        notes,
        from_content_type: previous.content_type ||
                           revision.source_content_type,
        from_filename: previous.filename || revision.source_filename,
        to_content_type: attachment.content_type,
        to_filename: attachment.filename
      )
    end

    def note_black_mask_fault(notes, black)
      notes['masking_fault'] = black.fault
      notes['served_after_fault'] = 'as_it_came'
      notes['unmasked_parts'] = black.unmasked if black.unmasked.any?
    end

    def html_file?(identity)
      return true if identity.content_type == 'text/html'
      return false if identity.filename.blank?

      filename = identity.filename
      [filename, FoiAttachment.display_form(filename)].any? do |name|
        AlaveteliFileTypes.filename_to_mimetype(name) == 'text/html'
      end
    end

    def admin_black_mask?
      return false if requester_edit?

      revision.instructions['black_mask'] == true || revision.kind == 'upload'
    end

    def requester_edit?
      revision.instructions['by_requester'] == true
    end

    def record_applied!(attachment)
      event = log_edit_event(attachment)
      revision.update!(status: 'applied',
                       applied_by: editor,
                       applied_at: Time.current,
                       reason: reason.presence,
                       info_request_event: event)
      event
    end

    def log_edit_event(attachment)
      return unless attachment.info_request

      attachment.info_request.log_event(
        'edit_attachment',
        editor: editor,
        reason: reason.presence || 'Redacted in editor',
        foi_attachment_id: attachment.id,
        attachment_management_revision_id: revision.id,
        attachment_management_kind: revision.kind,
        output_sha256: revision.output_sha256,
        engine: revision.engine
      )
    end

    def cleanup_working_copies!(attachment)
      Revision.open.where(foi_attachment_id: attachment.id).
        where.not(id: revision.id).find_each { _1.leave!('superseded') }
      revision.output.purge if revision.output.attached?
      Previews.clear(attachment.id)
      return unless attachment.info_request

      RegulatorPack.purge_for_request!(attachment.info_request.id) if defined?(RegulatorPack)
    end

    def handle_publication_state!(attachment, publish:, was_public:, premask:)
      state = publication_state(attachment)
      state.settle!(publish: publish, was_public: was_public, premask: premask)
      @demoted_from_public = state.demoted_from_public?
    end
  end
end
