# Holds spreadsheets flagged by ExcelAnalyzer from requesters until an admin
# releases them (never disclosing findings). New spreadsheets stay hidden
# until analyzed (waiting?); SpreadsheetCheckJob ensures analysis runs.
class FoiAttachment::SpreadsheetHold
  REASON = N_('We’ve held this file back while we check it. You don’t need ' \
              'to do anything.').freeze

  attr_reader :blob, :metadata

  def self.held?(attachment)
    attachment.prominence == 'hidden' &&
      attachment.prominence_reason == _(REASON)
  end

  def self.spreadsheet?(attachment)
    filename = attachment.filename
    if ExcelAnalyzer.monitored?(content_type: attachment.content_type,
                                filename: filename)
      return true
    end

    # Read via attachment so preloaded file_attachment: :blob avoids N+1.
    blob = attachment.file.attached? ? attachment.file.blob : nil
    return false unless blob

    ExcelAnalyzer.monitored?(
      content_type: blob.content_type,
      filename: blob.filename.to_s.presence || filename
    )
  end

  # Not read yet, so the requester waits (Ability).
  def self.waiting?(attachment)
    spreadsheet?(attachment) && attachment.file.attached? &&
      !attachment.file.analyzed?
  end

  # Unanalyzed monitored files, for recovery jobs after an interrupted parse.
  def self.unread
    FoiAttachment.joins(:file_blob).
      where(*monitored_sql).
      where.not('active_storage_blobs.metadata LIKE ?', '%"analyzed":true%')
  end

  def self.monitored_sql
    types = ExcelAnalyzer.content_types
    ole = ExcelAnalyzer::OLE2_CONTENT_TYPE
    att_ole, att_params = ole_name_sql(
      normalized_name_sql('foi_attachments.filename')
    )
    blob_expr = 'COALESCE(NULLIF(BTRIM(active_storage_blobs.filename), ' \
                "''), foi_attachments.filename)"
    blob_ole, blob_params = ole_name_sql(normalized_name_sql(blob_expr))
    sql = 'LOWER(foi_attachments.content_type) IN (?) OR ' \
          'LOWER(active_storage_blobs.content_type) IN (?) OR ' \
          "(LOWER(foi_attachments.content_type) = ? AND (#{att_ole})) OR " \
          "(LOWER(active_storage_blobs.content_type) = ? AND (#{blob_ole}))"
    [sql, types, types, ole, *att_params, ole, *blob_params]
  end
  private_class_method :monitored_sql

  def self.normalized_name_sql(expr)
    "LOWER(RTRIM(BTRIM(COALESCE(#{expr}, '')), '.'))"
  end
  private_class_method :normalized_name_sql

  def self.ole_name_sql(name_expr)
    checks = ["#{name_expr} NOT LIKE '%.%'"]
    params = []
    ExcelAnalyzer.ole2_extensions.each do |ext|
      checks << "#{name_expr} LIKE ?"
      params << "%#{ext}"
    end
    [checks.join(' OR '), params]
  end
  private_class_method :ole_name_sql

  # After a parse, whether or not it finished: see SpreadsheetCheckJob.
  def self.check_later(message)
    return unless message.foi_attachments.any? { spreadsheet?(_1) }

    job = FoiAttachment::SpreadsheetCheckJob
    job.set(wait: job::WAITS.first).perform_later(message.id)
  end

  def initialize(blob, metadata)
    @blob = blob
    @metadata = metadata
  end

  def run
    # Already analyzed: don't re-hold or undo an admin release.
    return if blob.analyzed?

    attachment = FoiAttachment.joins(:file_blob).
      find_by(active_storage_blobs: { id: blob.id }) or return
    return unless attachment.incoming_message

    if attachment.prominence == 'hidden'
      return unless self.class.held?(attachment)
    else
      return if names_and_links_only? && !looks_personal?(attachment)

      attachment.update_and_log_event!(
        prominence: 'hidden',
        prominence_reason: _(REASON),
        event: { editor: User.internal_admin_user,
                 reason: 'Spreadsheet analyzer: possible hidden data' }
      )
    end
    SpreadsheetHoldMailer.report(attachment, metadata).
      deliver_later(queue: :default)
  rescue AlaveteliSandbox::Refused
    raise
  rescue StandardError => e
    Rails.logger.error("FoiAttachment::SpreadsheetHold blob #{blob.id}: " \
                       "#{e.class}: #{e.message}")
    raise
  end

  private

  # Named ranges + external links only: held only if file looks personal.
  def names_and_links_only?
    counts = metadata.to_h.symbolize_keys
    return false if counts[:error]

    counts[:named_ranges].to_i.positive? &&
      counts[:external_links].to_i.positive? &&
      counts.except(:named_ranges, :external_links).values.sum(&:to_i).zero?
  end

  # Fails closed (returns true) for containers, embedded spreadsheets,
  # errors, or when PiiCheck is off/unavailable.
  def looks_personal?(attachment)
    unless blob && ExcelAnalyzer::XlsxAnalyzer::CONTENT_TYPES.
                   include?(blob.content_type.to_s.downcase)
      return true
    end

    bytes = attachment.file.download
    return true unless OfficePackage.package?(bytes)

    has_embedded = false
    texts = OfficePackage::Isolated.read(%w[content_texts embedded_excel],
                                         bytes: bytes) do |read|
      has_embedded = embedded_content?(read.value('embedded_excel'))
      read.value('content_texts')
    end
    return true if has_embedded

    text = PiiCheck.deduplicated(texts).join("\n")
    return true if text.match?(MySociety::Validate.email_find_regexp)
    return true unless PiiCheck.enabled?

    PiiCheck.call(text) != :clear
  rescue AlaveteliSandbox::Refused
    raise
  rescue StandardError => e
    Rails.logger.warn('spreadsheet_hold_personal_check_failed ' \
                      "attachment_id=#{attachment.id} #{e.class}")
    true
  end

  def embedded_content?(embedded)
    embedded[:spreadsheets].any? ||
      embedded[:errors].any? ||
      embedded[:legacy_xls].any?
  end
end
