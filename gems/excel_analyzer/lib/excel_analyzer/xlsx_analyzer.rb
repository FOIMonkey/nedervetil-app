require "active_storage"
require "active_storage/analyzer"

require "excel_analyzer/probe"

module ExcelAnalyzer
  ##
  # The Analyzer class is responsible for analyzing Excel (.xlsx) files uploaded
  # through Active Storage.
  #
  class XlsxAnalyzer < ActiveStorage::Analyzer
    include ExcelAnalyzer::Probe

    CONTENT_TYPE =
      "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet".freeze

    # A macro-enabled workbook or a template is the same zip of sheets.
    CONTENT_TYPES = [
      CONTENT_TYPE,
      "application/vnd.ms-excel.sheet.macroenabled.12",
      "application/vnd.openxmlformats-officedocument.spreadsheetml.template",
      "application/vnd.ms-excel.template.macroenabled.12"
    ].freeze

    OLE2_CONTENT_TYPE = 'application/x-ole-storage'.freeze
    OLE2_EXTENSIONS = %w[.xlsx .xlsm .xltx .xltm].freeze

    def self.accept?(blob)
      type = blob.content_type.to_s.downcase
      return true if CONTENT_TYPES.include?(type)
      return false unless blob.respond_to?(:filename)

      ExcelAnalyzer.ole2_type?(type, blob.filename, OLE2_EXTENSIONS)
    end

    def metadata
      data = excel_metadata

      if suspected_problem?(data)
        ExcelAnalyzer.on_hidden_metadata.call(blob, data)
      end

      { excel: data }
    end

    private

    def excel_metadata
      download_blob_to_tempfile { |io| probe(io) }
    rescue StandardError => ex
      raise if ExcelAnalyzer.retryable_error?(ex)

      { error: ex.message }
    end
  end
end
