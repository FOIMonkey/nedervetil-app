Rails.application.config.to_prepare do
  PDFRedactor.backend = PDFRedactor::Isolated
end
