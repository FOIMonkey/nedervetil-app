# frozen_string_literal: true

require 'active_storage'
require 'active_storage/analyzer'

require 'excel_analyzer/probe'
require 'excel_analyzer/xls_analyzer'
require 'excel_analyzer/office_embedded_analyzer'

module ExcelAnalyzer
  ##
  # Scans ZIP attachments for spreadsheets (.xlsx/.xlsm/.xltx/.xltm/.xls),
  # Office files carrying embedded spreadsheets (.docx/.docm/.pptx/.pptm), and
  # nested ZIP archives (up to MAX_DEPTH), holding the ZIP if any inner
  # spreadsheet is suspected of carrying hidden data.
  class ZipAnalyzer < ActiveStorage::Analyzer
    include ExcelAnalyzer::Probe

    CONTENT_TYPE = 'application/zip'
    CONTENT_TYPES = [
      CONTENT_TYPE,
      'application/x-zip-compressed'
    ].freeze

    MAX_DEPTH = 2
    MAX_ENTRIES = 500
    MAX_ENTRY = 25 * 1024 * 1024
    MAX_TOTAL = 50 * 1024 * 1024
    MAX_ZIP_FILE = 100 * 1024 * 1024
    MAX_XLS = 10

    OOXML_SHEET_EXTS = %w[.xlsx .xlsm .xltx .xltm].freeze
    XLS_EXTS = %w[.xls .xlsb].freeze
    OFFICE_EMBED_EXTS = %w[.docx .docm .pptx .pptm].freeze
    SENSITIVE_SKIP_EXTS = (
      OOXML_SHEET_EXTS + XLS_EXTS + OFFICE_EMBED_EXTS + %w[.zip]
    ).freeze

    def self.accept?(blob)
      CONTENT_TYPES.include?(blob.content_type.to_s.downcase)
    end

    def metadata
      data = zip_metadata
      return {} unless data

      if suspected_problem?(data)
        ExcelAnalyzer.on_hidden_metadata.call(blob, data)
      end

      { excel: data }
    end

    private

    def zip_metadata
      download_blob_to_tempfile do |io|
        if File.size(io.path) > MAX_ZIP_FILE
          return { error: 'zip archive too large' }
        end

        budget = { entries: 0, bytes: 0 }
        results = []
        ExcelAnalyzer.with_xls_budget(MAX_XLS) do
          scan_zip({ path: io.path }, depth: 0, budget: budget,
                                      results: results)
        end
        combine_problems(results)
      end
    rescue StandardError => e
      raise if ExcelAnalyzer.retryable_error?(e)

      { error: e.message }
    end

    def scan_zip(source, depth:, budget:, results:)
      if depth >= MAX_DEPTH
        results << { error: 'zip archive nested too deeply' }
        return
      end

      limits = remaining_limits(budget)
      unless limits
        results << { error: 'zip archive exceeds scan limits' }
        return
      end

      yielded = 0
      outcome = read_zip_entries(source, limits) do |filename, entry_bytes|
        budget[:entries] += 1
        yielded += 1
        if budget[:entries] > MAX_ENTRIES ||
           budget[:bytes] + entry_bytes.bytesize > MAX_TOTAL
          results << { error: 'zip archive exceeds scan limits' } unless
            flagged?(results)
          break
        end

        budget[:bytes] += entry_bytes.bytesize
        inspect_entry(filename, entry_bytes, depth: depth, budget: budget,
                                             results: results)
        break if flagged?(results)
      end
      record_zip_outcome(outcome, yielded, budget, results)
    end

    def record_zip_outcome(outcome, yielded, budget, results)
      seen = outcome.is_a?(Hash) ? outcome[:seen] : outcome
      skipped = outcome.is_a?(Hash) ? Array(outcome[:skipped]) : []
      if !flagged?(results) && skipped_sensitive?(skipped)
        results << { error: 'unreadable spreadsheet or archive entry in zip' }
      end
      return unless seen.is_a?(Integer) && seen > yielded

      budget[:entries] += seen - yielded
    end

    def flagged?(results)
      results.any? { |item| suspected_problem?(item) }
    end

    def skipped_sensitive?(names)
      names.any? do |name|
        SENSITIVE_SKIP_EXTS.include?(ExcelAnalyzer.normalized_extname(name))
      end
    end

    def remaining_limits(budget)
      max_entries = MAX_ENTRIES - budget[:entries]
      max_total = MAX_TOTAL - budget[:bytes]
      return nil if max_entries <= 0 || max_total <= 0

      { max_entries: max_entries, max_entry: MAX_ENTRY, max_total: max_total }
    end

    def read_zip_entries(source, limits, &block)
      reader = ExcelAnalyzer.zip_reader
      return reader.call(source, limits, &block) if reader

      read_zip_locally(source, limits, &block)
    end

    def read_zip_locally(source, limits, &block)
      skipped = []
      if source[:path]
        OfficePackage::Guard.check!(source[:path])
        seen = OfficePackage::Guard.each_entry(source[:path], **limits,
                                               skipped: skipped, &block)
        return { seen: seen, skipped: skipped }
      end

      Tempfile.create(['excel-zip', '.zip']) do |file|
        file.binmode
        file.write(source[:bytes])
        file.flush
        OfficePackage::Guard.check!(file.path)
        seen = OfficePackage::Guard.each_entry(file.path, **limits,
                                               skipped: skipped, &block)
        { seen: seen, skipped: skipped }
      end
    end

    def inspect_entry(filename, entry_bytes, depth:, budget:, results:)
      ext = ExcelAnalyzer.normalized_extname(filename)
      if OOXML_SHEET_EXTS.include?(ext)
        results << safe_probe(entry_bytes, ext)
      elsif XLS_EXTS.include?(ext)
        results << probe_inner_xls(entry_bytes, ext)
      elsif OFFICE_EMBED_EXTS.include?(ext)
        found = OfficeEmbeddedAnalyzer.probe_bytes(entry_bytes, extension: ext)
        results << found if found
      elsif ext == '.zip'
        scan_zip({ bytes: entry_bytes }, depth: depth + 1, budget: budget,
                                         results: results)
      end
    end

    def safe_probe(bytes, ext)
      probe_bytes(bytes, extension: ext)
    rescue StandardError => e
      raise if ExcelAnalyzer.retryable_error?(e)

      { error: e.message }
    end

    def probe_inner_xls(bytes, ext)
      if !ext.casecmp?('.xlsb') && bytes.byteslice(0, 4) == XlsAnalyzer::ZIP_MAGIC
        return safe_probe(bytes, '.xlsx')
      end

      XlsAnalyzer.probe_bytes(bytes, extension: ext)
    end
  end
end
