# frozen_string_literal: true

require 'tempfile'

require 'active_storage'
require 'active_storage/analyzer'

require 'excel_analyzer/probe'
require 'excel_analyzer/xls_analyzer'

module ExcelAnalyzer
  ##
  # Scans Word (.docx/.docm) and PowerPoint (.pptx/.pptm) files for embedded
  # spreadsheets (/embeddings/*). Embedded OOXML spreadsheets are probed
  # directly; embedded legacy binary .xls files are converted via LibreOffice
  # and probed.
  class OfficeEmbeddedAnalyzer < ActiveStorage::Analyzer
    include ExcelAnalyzer::Probe

    CONTENT_TYPES = [
      'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
      'application/vnd.ms-word.document.macroenabled.12',
      'application/vnd.openxmlformats-officedocument.presentationml.' \
      'presentation',
      'application/vnd.ms-powerpoint.presentation.macroenabled.12'
    ].freeze
    OLE2_MAGIC = "\xD0\xCF\x11\xE0\xA1\xB1\x1A\xE1".b.freeze
    OLE2_CONTENT_TYPE = 'application/x-ole-storage'
    OLE2_EXTENSIONS = %w[.docx .docm .pptx .pptm].freeze

    def self.accept?(blob)
      type = blob.content_type.to_s.downcase
      return true if CONTENT_TYPES.include?(type)
      return false unless blob.respond_to?(:filename)

      ExcelAnalyzer.ole2_type?(type, blob.filename, OLE2_EXTENSIONS,
                               allow_empty: true)
    end

    def self.probe_bytes(bytes, extension: '.docx')
      Tempfile.create(['embedded-office', extension]) do |file|
        file.binmode
        file.write(bytes)
        file.flush
        new(nil).send(:scan_path, file.path)
      end
    end

    def metadata
      data = download_blob_to_tempfile { |io| scan_path(io.path) }
      return {} unless data

      if suspected_problem?(data)
        ExcelAnalyzer.on_hidden_metadata.call(blob, data)
      end

      { excel: data }
    end

    private

    def scan_path(path)
      head = File.binread(path, 8).to_s.b
      return nil unless head.start_with?(XlsAnalyzer::ZIP_MAGIC, OLE2_MAGIC)

      results = read_embedded(path)
      combine_problems(results)
    rescue StandardError => e
      raise if ExcelAnalyzer.retryable_error?(e)
      # Non-OOXML files (e.g. a plain zip mislabelled .docx) have no OOXML
      # embeddings; only fail closed on actual embedded-spreadsheet errors.
      return nil if non_package_error?(e)

      { error: e.message }
    end

    def read_embedded(path)
      reader = ExcelAnalyzer.embedded_reader
      return reader.call(path) if reader

      bytes = File.binread(path)
      results = []
      unless bytes.b.start_with?(OLE2_MAGIC)
        begin
          results << OfficePackage::ExcelMetadata.call(bytes)
        rescue OfficePackage::NotPackage
          nil
        end
      end
      embedded = OfficePackage::ExcelMetadata.embedded(bytes) do |_part, xls|
        results << XlsAnalyzer.probe_bytes(xls)
      end
      collect_embedded(embedded, results)
    end

    def collect_embedded(embedded, results)
      embedded[:spreadsheets].each { |item| results << item[:counts] }
      embedded[:errors].each { |item| results << { error: item[:error] } }
      results
    end

    def non_package_error?(error)
      defined?(OfficePackage::NotPackage) &&
        error.is_a?(OfficePackage::NotPackage)
    end
  end
end
