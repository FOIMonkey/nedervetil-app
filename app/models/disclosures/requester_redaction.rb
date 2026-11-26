module Disclosures
  # Applies a requester's own PDF box redaction, text edit, or Word-to-PDF
  # conversion during the publish steps.
  class RequesterRedaction
    # continue_from holds the draft PDF revision after a Word conversion.
    Result = Data.define(:notice, :continue_from)

    attr_reader :document, :user, :ability

    def initialize(document, user:, ability:)
      @document = document
      @user = user
      @ability = ability
    end

    def apply!(kind:, boxes: nil, text: nil, parent_id: nil, reason: nil)
      attachment = document.foi_attachment
      raise Error::Refused, _('This file is no longer there.') unless attachment

      ensure_allowed!(attachment, kind, parent_id)
      revision, input = AttachmentManagement::NewRevision.new(
        attachment, user: user, ability: ability, allow_word_pdf: true
      ).build(kind, boxes: boxes, text: text, parent_id: parent_id)
      return convert_word_to_pdf!(revision) if kind == 'office_pdf'

      process!(attachment, revision, input)
      AttachmentManagement::Replacement.new(
        revision, editor: user, reason: reason
      ).apply!(publish: true)
      Result.new(notice: applied_notice, continue_from: nil)
    end

    private

    def ensure_allowed!(attachment, kind, parent_id)
      capabilities = AttachmentManagement::Capabilities.new(attachment)
      allowed = case kind
                when 'text_edit'
                  document.source_kind == 'email_text' ||
                  attachment.main_body_part?
                when 'pdf_redaction'
                  if parent_id.present?
                    capabilities.word_processing?
                  else
                    capabilities.kind == :pdf
                  end
                when 'office_pdf'
                  capabilities.requester_word_to_pdf?
                else
                  false
                end
      return if allowed

      raise Error::Refused,
            _('An admin must handle redactions on this file.')
    end

    def convert_word_to_pdf!(revision)
      revision.save!
      AttachmentManagement::Processor.new(revision).run
      revision.reload
      if revision.failed?
        raise Error::Refused, revision.error.presence || _('Conversion failed.')
      end

      Result.new(notice: nil, continue_from: revision)
    end

    def process!(attachment, revision, input)
      source_bytes = public_masked_pdf_source(attachment, revision)
      revision.save!
      if input
        revision.output.attach(io: StringIO.new(input.b),
                               filename: 'input',
                               content_type: 'application/octet-stream',
                               identify: false)
      end

      AttachmentManagement::Processor.new(revision,
                                          source_bytes: source_bytes).run
      revision.reload
      return unless revision.failed?

      raise Error::Refused, revision.error.presence || _('Redaction failed.')
    end

    # Boxes flatten a PDF's pages to pictures, which no rule can mask
    # afterwards, so the public rules go on before the boxes are drawn.
    def public_masked_pdf_source(attachment, revision)
      return unless revision.kind == 'pdf_redaction'

      if revision.parent
        return Masking.public_masked_bytes(
          revision.parent.output_bytes,
          attachment,
          document,
          content_type: 'application/pdf',
          filename: revision.parent.output_filename
        )
      end
      return if attachment.rasterized?

      Masking.public_masked_bytes(attachment.body, attachment, document)
    end

    def applied_notice
      if ReviewSubmission.pending?(document.reload)
        _('Redactions saved. An admin will check this file before ' \
          'it goes public.')
      else
        _('Redactions saved and shared publicly.')
      end
    end
  end
end
