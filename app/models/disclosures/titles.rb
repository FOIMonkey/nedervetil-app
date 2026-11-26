module Disclosures
  # Never the file's name (it can name people) or a copy of the request's
  # title (an admin may later edit that to remove something).
  module Titles
    module_function

    def suggest(kind, request, date)
      label = _(Document::KIND_LABELS.fetch(kind, N_('Document')))
      body = request.public_body&.name
      [
        label,
        (PlainTextTranslation._('from {{authority}}', authority: body) if body),
        (DocumentsHelper.document_date(date) if date)
      ].compact.join(' ').
        sub(/ (\d{1,2} \w+ \d{4})\z/, ', \\1').truncate(200)
    end

    # True when the requester replaced the generated title.
    def own_title?(document)
      document.info_request.present? &&
        document.title != suggest(document.kind, document.info_request,
                                  document.released_on)
    end

    def own_words?(document)
      own_title?(document) || document.description.present?
    end

    def filename(title, extension)
      stem = title.to_s.parameterize.first(80).presence || 'document'
      "#{stem}#{extension}"
    end
  end
end
