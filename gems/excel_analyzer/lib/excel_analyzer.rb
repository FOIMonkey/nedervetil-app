# frozen_string_literal: true

require 'excel_analyzer/eml_analyzer'
require 'excel_analyzer/xls_analyzer'
require 'excel_analyzer/xlsx_analyzer'
require 'excel_analyzer/office_embedded_analyzer'
require 'excel_analyzer/zip_analyzer'
require 'excel_analyzer/railtie' if defined?(Rails)

##
# This module provides functionality to analyze Excel files, ZIP archives and
# Office documents for hidden data within spreadsheet attachments. It supports
# .xls, .xlsx/.xlsm/.xltx/.xltm, .zip archives and embedded spreadsheets inside
# .docx/.pptx/.xlsx files.
module ExcelAnalyzer
  OLE2_CONTENT_TYPE = 'application/x-ole-storage'

  # A configurable callable that gets executed when an email with a spreadsheet
  # or ZIP attachment is analyzed.
  mattr_accessor :on_spreadsheet_received, default: ->(_blob) {}

  # A configurable callable that gets executed when an analyzed file contains
  # signs of hidden spreadsheet data.
  mattr_accessor :on_hidden_metadata, default: ->(_blob, _metadata) {}

  # A callable given a workbook's path that returns what Metadata#to_h gives
  # for it, for an app that reads workbooks in a sandboxed worker.
  mattr_accessor :metadata_reader, default: nil

  # A callable given a .docx/.pptx path that returns an Array of per-embedded-
  # spreadsheet metadata hashes (or { error: ... } hashes).
  mattr_accessor :embedded_reader, default: nil

  # A callable given (bytes, limits, &block) that checks the ZIP guard, yields
  # each readable [filename, entry_bytes], and returns the number of entries
  # seen.
  mattr_accessor :zip_reader, default: nil

  # A callable given a .xls/.xlsb OLE2 path that returns an error string if
  # the compound file is encrypted or corrupt, or nil if it may be converted.
  mattr_accessor :ole2_checker, default: nil

  # Error classes indicating a temporary inability to scan (such as a
  # sandboxed converter cell being down or busy). Propagated so Active Storage
  # leaves the blob unanalyzed for retry instead of permanently holding it.
  mattr_accessor :retryable_errors, default: []

  def self.retryable_error?(error)
    retryable_errors.any? { |klass| error.is_a?(klass) }
  end

  # Content types that wait for analysis before download (SpreadsheetHold):
  # .xls, .xlsb, .xlsx/.xlsm/.xltx/.xltm, .zip archives and .docx/.pptx files
  # scanned for embedded spreadsheets.
  def self.content_types
    [*XlsAnalyzer::CONTENT_TYPES,
     *XlsxAnalyzer::CONTENT_TYPES,
     *ZipAnalyzer::CONTENT_TYPES,
     *OfficeEmbeddedAnalyzer::CONTENT_TYPES]
  end

  def self.ole2_extensions
    [*XlsAnalyzer::OLE2_EXTENSIONS,
     *XlsxAnalyzer::OLE2_EXTENSIONS,
     *OfficeEmbeddedAnalyzer::OLE2_EXTENSIONS]
  end

  def self.normalized_extname(filename)
    clean = filename.to_s.tr('\\', '/').strip.sub(/\.+\z/, '')
    ext = File.extname(clean).downcase
    return ext unless ext.empty?

    base = File.basename(clean).downcase
    base.start_with?('.') && base.length > 1 ? base : ''
  end

  def self.ole2_type?(content_type, filename, extensions, allow_empty: false)
    return false unless content_type.to_s.downcase == OLE2_CONTENT_TYPE

    ext = normalized_extname(filename)
    (allow_empty && ext.empty?) || extensions.include?(ext)
  end

  def self.monitored?(content_type:, filename: nil)
    type = content_type.to_s.downcase
    return true if content_types.include?(type)

    ole2_type?(type, filename, ole2_extensions, allow_empty: true)
  end

  # Caps legacy .xls LibreOffice conversions across a composite scan (such as
  # a ZIP containing both .xls files and .docx/.xlsx files with embedded .xls).
  def self.with_xls_budget(max)
    previous = Thread.current[:excel_analyzer_xls_budget]
    Thread.current[:excel_analyzer_xls_budget] = { count: 0, max: max }
    yield
  ensure
    Thread.current[:excel_analyzer_xls_budget] = previous
  end

  def self.consume_xls_budget!
    budget = Thread.current[:excel_analyzer_xls_budget]
    return true unless budget

    budget[:count] += 1
    budget[:count] <= budget[:max]
  end

  # Merges any suspected embedded spreadsheet results onto a workbook's base
  # counts hash.
  def self.combine_with_base(base, extra_results)
    helper = Object.new.extend(Probe)
    embedded = helper.combine_problems(extra_results)
    return base unless embedded
    return embedded if embedded[:error]
    return base if base[:error]

    Probe::ZERO_COUNTS.each_with_object({}) do |(key, _zero), merged|
      merged[key] = base[key].to_i + embedded[key].to_i
    end
  end
end
