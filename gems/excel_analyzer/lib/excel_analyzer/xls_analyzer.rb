# frozen_string_literal: true

require 'open3'
require 'tempfile'
require 'tmpdir'

require 'active_storage'
require 'active_storage/analyzer'

require 'excel_analyzer/probe'

module ExcelAnalyzer
  ##
  # The Analyzer class is responsible for analyzing Excel (.xls) files uploaded
  # through Active Storage.
  #
  # Files that are already OOXML ZIPs misnamed .xls are probed directly without
  # starting LibreOffice. Legacy binary .xls files are converted to XLSX format
  # first and then probed for hidden data.
  class XlsAnalyzer < ActiveStorage::Analyzer
    include ExcelAnalyzer::Probe

    CONTENT_TYPE = 'application/vnd.ms-excel'
    XLSB_CONTENT_TYPE = 'application/vnd.ms-excel.sheet.binary.macroenabled.12'
    CONTENT_TYPES = [
      CONTENT_TYPE,
      'application/x-ms-excel',
      XLSB_CONTENT_TYPE
    ].freeze

    ZIP_MAGIC = "PK\x03\x04".b.freeze
    OLE2_MAGIC = "\xD0\xCF\x11\xE0\xA1\xB1\x1A\xE1".b.freeze

    # The largest converted workbook that will be probed.
    MAX_XLSX = 256 * 1024 * 1024

    OLE2_CONTENT_TYPE = 'application/x-ole-storage'
    OLE2_EXTENSIONS = %w[.xls .xlsb].freeze

    def self.accept?(blob)
      type = blob.content_type.to_s.downcase
      return true if CONTENT_TYPES.include?(type)
      return false unless blob.respond_to?(:filename)

      ExcelAnalyzer.ole2_type?(type, blob.filename, OLE2_EXTENSIONS)
    end

    # Probes raw .xls/.xlsb bytes (converting through LibreOffice if legacy
    # OLE2 or .xlsb, or probing directly if a misnamed OOXML ZIP). Returns
    # { error: ... } on any conversion or probe error.
    def self.probe_bytes(bytes, extension: '.xls')
      fast_path = !extension.casecmp?('.xlsb') &&
                  bytes.byteslice(0, 4) == ZIP_MAGIC
      if !fast_path && !ExcelAnalyzer.consume_xls_budget!
        return { error: 'too many legacy spreadsheets' }
      end

      Tempfile.create(['embedded', extension]) do |file|
        file.binmode
        file.write(bytes)
        file.flush
        new(nil).send(:convert_and_probe, file)
      end
    rescue StandardError => e
      raise if ExcelAnalyzer.retryable_error?(e)

      { error: e.message }
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
      download_blob_to_tempfile { |io| convert_and_probe(io) }
    rescue StandardError => e
      raise if ExcelAnalyzer.retryable_error?(e)

      { error: e.message }
    end

    def convert_and_probe(io)
      return probe(io) if ooxml_zip?(io.path)

      ole2_error = check_ole2(io.path)
      return { error: ole2_error } if ole2_error

      converted = convert(io)
      begin
        probe(converted)
      ensure
        converted&.close!
      end
    end

    def check_ole2(path)
      return nil unless File.binread(path, 8).to_s.b.start_with?(OLE2_MAGIC)

      checker = ExcelAnalyzer.ole2_checker
      return checker.call(path) if checker
      return nil unless defined?(OfficePackage::CompoundFile)

      file = OfficePackage::CompoundFile.new(File.binread(path))
      file.encrypted? ? 'encrypted Office document' : nil
    rescue StandardError => e
      raise if ExcelAnalyzer.retryable_error?(e)

      e.message
    end

    def ooxml_zip?(path)
      return false if xlsb?(path)

      File.binread(path, 4) == ZIP_MAGIC
    end

    def xlsb?(path)
      File.extname(path).casecmp?('.xlsb') ||
        blob&.content_type.to_s.casecmp?(XLSB_CONTENT_TYPE)
    end

    def convert(io)
      return convert_in_job(io) if defined?(::AlaveteliSandbox)
      raise 'LibreOffice (soffice) command not found' unless soffice_installed?

      Dir.mktmpdir do |tmpdir|
        _stdout, _stderr, status = Open3.capture3(
          'soffice', '--headless', '--convert-to', 'xlsx', '--outdir', tmpdir,
          io.path
        )

        path = File.join(tmpdir, "#{File.basename(io.path, '.*')}.xlsx")

        if !status.success? || !File.exist?(path)
          raise 'LibreOffice conversion failed'
        end

        Tempfile.new(['spreadsheet', '.xlsx']).tap do |tempfile|
          tempfile.binmode
          tempfile.write(File.binread(path))
          tempfile.rewind
        end
      end
    end

    # In Alaveteli, LibreOffice runs through AlaveteliSandbox: sandboxed when
    # SANDBOX_CONVERTERS is required, directly otherwise.
    def convert_in_job(io)
      # LibreOffice picks its import filter by extension, so the file keeps
      # its own (when it's a plain one), as it did when converted in place.
      extension = File.extname(io.path).downcase
      extension = '.xlsb' if extension.empty? && xlsb?(io.path)
      extension = '' unless extension.match?(/\A\.[a-z0-9]{1,8}\z/)
      name = "spreadsheet#{extension}"
      ::AlaveteliSandbox.job(input: Pathname(io.path),
                             input_name: name) do |job|
        job.run('soffice', '--headless', '--convert-to', 'xlsx',
                '--outdir', job.scratch, job.input,
                timeout: 300, memory: 4 * 1024 * 1024 * 1024)
        unless job.exist?('spreadsheet.xlsx')
          raise 'LibreOffice conversion failed'
        end

        Tempfile.new(['spreadsheet', '.xlsx']).tap do |tempfile|
          tempfile.binmode
          job.copy_out('spreadsheet.xlsx', to: tempfile, max: MAX_XLSX)
          tempfile.rewind
        end
      end
    end

    def soffice_installed?
      system('which soffice > /dev/null 2>&1')
    end
  end
end
