module AttachmentManagement
  # What the management screens can do with an attachment, from its type.
  class Capabilities
    PDF = %w[application/pdf].freeze
    WORD_PROCESSING = (
      AttachmentToText::MS_WORD_DOCS + AttachmentToText::WORD_PROCESSING_DOCS +
      %w[application/msword application/rtf text/rtf]
    ).freeze
    OFFICE = (
      WORD_PROCESSING +
      AttachmentToText::MS_EXCEL_DOCS + AttachmentToText::SPREADSHEET_DOCS +
      AttachmentToText::MS_POWERPOINT_DOCS +
      AttachmentToText::PRESENTATION_DOCS
    ).freeze
    # RTF is text on the wire but is edited as an Office document.
    TEXT = (AlaveteliTextMasker::TEXT_MASK - %w[text/rtf]).freeze

    attr_reader :attachment

    def initialize(attachment)
      @attachment = attachment
    end

    def kind
      @kind ||=
        if attachment.main_body_part? || TEXT.include?(content_type)
          :text
        elsif PDF.include?(content_type)
          :pdf
        elsif Engines::Raster::IMAGE_CODERS.key?(content_type)
          :image
        elsif OFFICE.include?(content_type)
          :office
        else
          :other
        end
    end

    def content_type
      attachment.content_type
    end

    def main_body?
      attachment.main_body_part?
    end

    def redact_boxes?
      %i[pdf image].include?(kind)
    end

    def edit_text?
      kind == :text
    end

    def convert_to_pdf?
      kind == :office && Command.available?('soffice')
    end

    def word_processing?
      WORD_PROCESSING.include?(content_type)
    end

    def requester_word_to_pdf?
      word_processing? && Command.available?('soffice')
    end

    def label
      return _('message text') if main_body?

      attachment.name_of_content_type.presence || content_type
    end

    def limitation
      case kind
      when :office
        _('Office files can’t be marked up in the browser. Download it, ' \
          'check it (hidden sheets, rows and columns, comments, tracked ' \
          'changes and document properties all travel with the file), and ' \
          'upload a reviewed copy, or convert it to PDF here and redact that.')
      when :other
        _('This format can’t be shown or edited here. Download it, ' \
          'check it on your own computer and upload a replacement.')
      end
    end
  end
end
