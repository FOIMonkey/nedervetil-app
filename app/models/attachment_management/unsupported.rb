module AttachmentManagement
  # Raised when a file can't be shown or processed; the message says why.
  class Unsupported < StandardError
    MESSAGES = {
      encrypted: N_('This PDF is protected with a password, ' \
                    'so it can’t be shown or redacted here.'),
      unreadable_pdf: N_('This file can’t be read as a PDF.'),
      unreadable_image: N_('This image can’t be read.'),
      multi_page_image: N_('This image has several pages. ' \
                           'Boxes can only be drawn on single-page images.'),
      conversion_failed: N_('LibreOffice couldn’t convert this file to PDF.'),
      too_large: N_('This file is too large to process here.'),
      not_supported: N_('Boxes can’t be drawn on this kind of file.')
    }.freeze

    attr_reader :reason

    def initialize(reason, detail = nil)
      @reason = reason
      super([_(MESSAGES.fetch(reason, MESSAGES[:not_supported])), detail].
            compact.join(' '))
    end

    def explanation
      _(MESSAGES.fetch(reason, MESSAGES[:not_supported]))
    end
  end
end
