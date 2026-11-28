require 'excel_analyzer'

ExcelAnalyzer.on_spreadsheet_received = ->(raw_email_blob) do
  incoming_message = IncomingMessage.joins(raw_email: :file_blob).
    find_by(active_storage_blobs: { id: raw_email_blob })
  incoming_message&.parse_raw_email
end

ExcelAnalyzer.on_hidden_metadata = ->(blob, metadata) do
  FoiAttachment::SpreadsheetHold.new(blob, metadata).run
end

# Read where the app reads Office files (OfficePackage::Isolated).
ExcelAnalyzer.metadata_reader = ->(path) do
  OfficePackage::Isolated.read(%w[guard_unpack excel embedded_excel],
                               path: path) do |read|
    AttachmentManagement::ZipGuard.checked!(read, unpack: true)
    counts = read.value('excel')
    embedded = read.value('embedded_excel')
    extra = embedded[:spreadsheets].map { |item| item[:counts] } +
            embedded[:errors].map { |item| { error: item[:error] } }
    read.each_embedded_xls do |_part, xls_bytes|
      extra << ExcelAnalyzer::XlsAnalyzer.probe_bytes(xls_bytes)
    end
    ExcelAnalyzer.combine_with_base(counts, extra)
  end
end

ExcelAnalyzer.embedded_reader = ->(path) do
  ole2 = File.binread(path, 8).to_s.b.
           start_with?(OfficePackage::COMPOUND_FILE_MAGIC)
  sections = ole2 ? %w[embedded_excel] : %w[guard excel embedded_excel]
  OfficePackage::Isolated.read(sections, path: path) do |read|
    AttachmentManagement::ZipGuard.checked!(read) unless ole2
    results = []
    unless ole2
      begin
        results << read.value('excel')
      rescue OfficePackage::NotPackage
        nil
      end
    end
    embedded = read.value('embedded_excel')
    results.concat(embedded[:spreadsheets].map { |item| item[:counts] })
    results.concat(embedded[:errors].map { |item| { error: item[:error] } })
    read.each_embedded_xls do |_part, xls_bytes|
      results << ExcelAnalyzer::XlsAnalyzer.probe_bytes(xls_bytes)
    end
    results
  end
end

ExcelAnalyzer.ole2_checker = ->(path) do
  OfficePackage::Isolated.read(%w[embedded_excel], path: path) do |read|
    read.value('embedded_excel')[:errors].first&.dig(:error)
  end
end

ExcelAnalyzer.zip_reader = ->(source, limits, &block) do
  OfficePackage::Isolated.read_zip(**source, zip: limits) do |read|
    AttachmentManagement::ZipGuard.checked!(read)
    seen = read.each_zip_entry(&block)
    { seen: seen, skipped: read.zip_skipped }
  end
end

Rails.application.config.to_prepare do
  # When the Office cell or sandbox refuses a scan (outage, deploy restart,
  # kill switch, full volume), analyzers let AlaveteliSandbox::Refused
  # propagate so the blob stays unanalyzed (SpreadsheetHold.waiting? stays
  # true). Discarding here avoids Sidekiq's retry/dead-set buildup while
  # FoiAttachment::SpreadsheetCheckJob owns the retry schedule (1m..18h).
  ExcelAnalyzer.retryable_errors = [AlaveteliSandbox::Refused]

  handled = ActiveStorage::AnalyzeJob.rescue_handlers.any? do |name, _|
    name == 'AlaveteliSandbox::Refused'
  end
  next if handled

  ActiveStorage::AnalyzeJob.discard_on(AlaveteliSandbox::Refused) do |job, err|
    blob = job.arguments.first
    Rails.logger.warn(
      "ActiveStorage::AnalyzeJob deferred blob #{blob&.id}: #{err.message}"
    )
  end
end
