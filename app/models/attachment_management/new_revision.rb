module AttachmentManagement
  # Builds a short-lived Revision working copy from FoiAttachment#file.
  class NewRevision
    Invalid = Class.new(StandardError)

    def initialize(attachment, user:, ability:, capabilities: nil, source: nil,
                   allow_word_pdf: false)
      @attachment = attachment
      @user = user
      @ability = ability
      @capabilities = capabilities || Capabilities.new(attachment)
      @source = source
      @allow_word_pdf = allow_word_pdf
    end

    def build(kind, shown: nil, boxes: nil, parent_id: nil, text: nil,
              upload: nil, black_mask: false)
      _ = shown
      kind = kind.to_s
      unless Revision::KINDS.include?(kind)
        raise Invalid, _('Unknown kind of draft.')
      end

      if kind != 'upload' && !available?
        raise Invalid, _('This attachment can’t be processed; ' \
                         'upload a replacement.')
      end

      bytes = current_bytes
      revision = Revision.new(
        foi_attachment: attachment,
        user: user,
        kind: kind,
        status: 'processing',
        source_sha256: Digest::SHA256.hexdigest(bytes),
        source_content_type: attachment.content_type,
        source_filename: attachment.display_filename
      )
      input = case kind
              when 'pdf_redaction'
                pdf_redaction(revision, boxes, parent_id, bytes)
              when 'image_redaction' then image_redaction(revision, boxes)
              when 'office_pdf' then office_pdf
              when 'text_edit' then text_edit(revision, text, bytes)
              when 'upload' then uploaded(revision, upload)
              end

      extra = extra_instructions(black_mask)
      revision.instructions = revision.instructions.merge(extra)
      [revision, input]
    end

    private

    attr_reader :attachment, :user, :ability, :capabilities

    def available?
      !attachment.erased? && !attachment.masking_failed? &&
        attachment.file.attached?
    end

    def current_bytes
      return '' unless attachment.file.attached?
      return attachment.file.download if attachment.masking_failed?

      attachment.body.to_s
    end

    def admin?
      ability.can?(:admin, attachment.info_request)
    end

    def by_requester?
      !admin? && user.id == attachment.info_request&.user_id
    end

    def pdf_redaction(revision, boxes, parent_id, bytes)
      parent = conversion_parent(parent_id, revision.source_sha256)
      unless parent || capabilities.kind == :pdf
        raise Invalid, _('Boxes can’t be drawn on this file.')
      end

      pages = if parent
                parent.previews.page_count
              else
                previews(bytes).page_count
              end
      revision.parent = parent
      revision.instructions = {
        'boxes' => Boxes.parse(boxes, pages).transform_keys(&:to_s)
      }
      nil
    rescue Unsupported => e
      raise Invalid, e.explanation
    end

    def conversion_parent(parent_id, source_sha256)
      return if parent_id.blank?

      parent = Revision.find_by(id: parent_id,
                                foi_attachment_id: attachment.id,
                                kind: 'office_pdf')
      allowed = ability.can?(:replace_attachment, attachment) ||
                (@allow_word_pdf && capabilities.word_processing? &&
                 parent&.user_id == user.id &&
                 parent.source_sha256 == source_sha256)
      unless parent&.ready? && ability.can?(:view_attachment_draft, parent) &&
             allowed
        raise Invalid, _('Boxes can’t be drawn on this file.')
      end

      parent
    end

    def image_redaction(revision, boxes)
      raise Invalid, _('Only an admin can redact images.') unless admin?
      unless capabilities.kind == :image
        raise Invalid, _('Boxes can’t be drawn on this file.')
      end

      parsed = Boxes.parse(boxes, 1)
      raise Invalid, _('Draw at least one box.') if parsed.empty?

      revision.instructions = { 'boxes' => parsed.transform_keys(&:to_s) }
      nil
    end

    def office_pdf
      unless ability.can?(:replace_attachment, attachment) ||
             (@allow_word_pdf && capabilities.word_processing?)
        raise Invalid, _('Only an admin can convert this file.')
      end
      unless capabilities.convert_to_pdf?
        raise Invalid, _('Only Office files are converted here.')
      end

      nil
    end

    def text_edit(revision, text, bytes)
      if (!admin? && !attachment.main_body_part?) ||
         !ability.can?(:edit_attachment_text, attachment)
        raise Invalid, _('Only an admin can edit this file.')
      end
      unless capabilities.edit_text?
        raise Invalid, _('This attachment isn’t edited as text.')
      end

      current_text = convert_string_to_utf8(bytes.dup, 'UTF-8').string
      text = text.to_s
      text = text.gsub("\r\n", "\n") unless current_text.include?("\r\n")
      raise Invalid, _('The text is unchanged.') if text == current_text
      if text.bytesize > AttachmentManagement.max_bytes
        raise Invalid, _('That text is too long.')
      end

      instructions = {}
      unless ability.can?(:replace_attachment, attachment)
        TextRedaction.check!(current_text, text)
        instructions['redaction_only'] = true
      end
      if !admin? && blue_rule_matches?(current_text)
        instructions['blue_rule_matched'] = true
      end
      revision.instructions = instructions if instructions.any?
      text.encode('UTF-8')
    end

    def blue_rule_matches?(text)
      request = attachment.info_request
      return false unless request

      rules = request.applicable_censor_rules.select(&:blue?)
      return false if rules.empty?

      Disclosures::RuleCheck.matched?(rules, text)
    rescue Disclosures::RuleCheck::Unreadable
      true
    end

    def uploaded(revision, upload)
      unless ability.can?(:replace_attachment, attachment)
        raise Invalid, _('Only an admin can upload a replacement.')
      end
      unless upload.respond_to?(:read)
        raise Invalid, _('Choose a file to upload.')
      end
      # rubocop:disable Style/ZeroLengthPredicate -- uploads have no empty?
      raise Invalid, _('That file is empty.') if upload.size.zero?
      # rubocop:enable Style/ZeroLengthPredicate
      if upload.size > AttachmentManagement.max_bytes
        raise Invalid, _('That file is too large.')
      end

      revision.instructions = {
        'upload_filename' => upload.original_filename.to_s.truncate(200),
        'upload_content_type' => upload.content_type.to_s
      }
      upload.read
    end

    def extra_instructions(black_mask)
      extra = { 'by_requester' => by_requester? }
      extra['black_mask'] = true if black_mask && admin?
      extra
    end

    def previews(bytes)
      Previews.new(attachment_id: attachment.id,
                   sha256: Digest::SHA256.hexdigest(bytes),
                   content_type: attachment.content_type) { bytes }
    end
  end
end
