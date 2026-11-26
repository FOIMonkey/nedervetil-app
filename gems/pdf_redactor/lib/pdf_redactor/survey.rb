# frozen_string_literal: true

module PDFRedactor
  # What each page shows that its text layer may not say: how much of the
  # page pictures cover, and how many glyphs draw nothing that maps to text.
  # Read only: Redactor walks the pages with no rules, and nothing is
  # written. Disclosures::Renderer reads the pages it flags with OCR.
  module Survey
    module_function

    # [{ 'number', 'visible', 'unmapped', 'picture_share' }, ...], one per
    # page: glyphs that map to text, glyphs that don't, and the share of the
    # page's area pictures cover.
    def pages(pdf)
      return PDFRedactor.backend.survey(pdf) if PDFRedactor.isolated?

      %w[none generalized].each do |level|
        qdf, = PDFRedactor.normalise(pdf, level)
        redactor = Redactor.new(QdfDoc.new(qdf).unshare_contents, [],
                                input: pdf)
        redactor.run
        return redactor.pages
      rescue NeedsFullDecode
        raise if level == 'generalized'
      end
    rescue SystemStackError
      raise Error, 'PDF nesting limit exceeded'
    end
  end
end
