# frozen_string_literal: true

require 'tempfile'

module OfficePackage
  module Isolated
    # A read of one file in this process, with the sandbox off: each section
    # calls its reader when it is asked for, as the app always has, and
    # raises what the reader raises.
    class InProcess
      READERS = {
        'guard' => ->(read) { Guard.check!(read.path) },
        'guard_unpack' => ->(read) { Guard.check!(read.path, unpack: true) },
        'inspector' => ->(read) { Inspector.findings(read.path) },
        'hidden' => ->(read) { Hidden.call(read.bytes) },
        'content_texts' => ->(read) {
          Hidden.new(OfficePackage.read(read.bytes)).content_texts
        },
        'sheets' => ->(read) { Sheets.read_xlsx(read.path, **read.sheets) },
        'excel' => ->(read) { ExcelMetadata.call(read.bytes) },
        'embedded_excel' => ->(read) { read.embedded_excel_result },
        'tidy' => ->(read) { Tidy.call(read.bytes).bytes }
      }.freeze

      attr_reader :sheets, :last_zip_index

      def initialize(path: nil, bytes: nil, sheets: nil, zip: nil)
        @path = path
        @bytes = bytes
        @sheets = sheets
        @zip = zip
        @embedded_xls = nil
      end

      def value(section)
        READERS.fetch(section).call(self)
      end

      def each_string
        Detector.call(bytes, ->(text) {
          yield text
          false
        })
        nil
      end

      def each_zip_entry
        positions = []
        @zip_skipped = []
        Guard.each_entry(path, **@zip, positions: positions,
                                       skipped: @zip_skipped) do |name, body|
          @last_zip_index = positions.last
          yield name, body
        end
      end

      def zip_skipped
        @zip_skipped || []
      end

      def each_embedded_xls
        embedded_excel_result unless @embedded_xls
        @embedded_xls.each { |part, data| yield part, data }
        nil
      end

      def embedded_excel_result
        return @embedded_result if @embedded_result

        @embedded_xls = []
        result = ExcelMetadata.embedded(bytes) do |part, data|
          @embedded_xls << [part, data]
        end
        legacy = @embedded_xls.map do |part, data|
          { part: part, size: data.bytesize }
        end
        @embedded_result = result.merge(legacy_xls: legacy)
      end

      def bytes
        @bytes ||= File.binread(@path)
      end

      # The readers that open a file by its name are given one for bytes.
      def path
        @path ||= begin
          @file = Tempfile.create('office-read')
          @file.binmode
          @file.write(@bytes)
          @file.close
          @file.path
        end
      end

      def close
        File.unlink(@file.path) if @file && File.exist?(@file.path)
      end
    end
  end
end
