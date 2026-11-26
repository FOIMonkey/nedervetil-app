require 'csv'

module Disclosures
  # Extracts visible workbook sheets and CSVs; hidden cells are excluded and
  # counted so hidden data never reaches page text, search, or clean copies.
  module Sheets
    # unformatted_cells: unsupported number formats (shown raw).
    # hidden_values: hidden cell values passed to HiddenRisk.
    Sheet = Struct.new(:name, :rows, :total_rows, :total_columns,
                       :hidden_cells, :unformatted_cells, :hidden_values,
                       keyword_init: true) do
      def truncated?
        total_rows > rows.size || total_columns > rows.map(&:size).max.to_i
      end

      def text
        rows.map do |row|
          row.map { |cell| cell.to_s.gsub(/[\t\r\n]+/, ' ') }.join("\t")
        end.join("\n")
      end
    end

    MAX_CELLS = OfficePackage::Sheets::MAX_CELLS
    MAX_READ_CELLS = OfficePackage::Sheets::MAX_READ_CELLS

    module_function

    # read: optional OfficePackage::Isolated read with guard and sheets.
    def read_xlsx(path, max_rows: Disclosures.sheet_max_rows, max_columns: Disclosures.sheet_max_columns, read: nil)
      return sheets_in(read) if read

      OfficePackage::Isolated.read(
        %w[guard sheets], path: path,
                          sheets: limits(max_rows: max_rows,
                                         max_columns: max_columns)
      ) { |own| sheets_in(own) }
    end

    def limits(max_rows: Disclosures.sheet_max_rows, max_columns: Disclosures.sheet_max_columns)
      { max_rows: max_rows, max_columns: max_columns,
        max_cells: MAX_CELLS, max_read_cells: MAX_READ_CELLS }
    end

    def sheets_in(read)
      ZipGuard.checked!(read)
      read.value('sheets').map { |sheet| Sheet.new(**sheet) }
    rescue OfficePackage::Sheets::Refused => e
      raise Error::Refused, refusal(e.reason)
    rescue OfficePackage::Guard::Refused => e
      raise AttachmentManagement::ZipGuard.refused(e)
    # Zip::Error: ZipGuard's, for a file that isn't a zip at all.
    rescue OfficePackage::Error, Zip::Error, Nokogiri::XML::SyntaxError => e
      Rails.logger.warn("Disclosures::Sheets spreadsheet unreadable: " \
                        "#{e.class}: #{e.message}")
      raise Error::Refused, _('This spreadsheet can’t be read.')
    end

    def refusal(reason)
      case reason
      when 'conditional_formatting'
        _('This spreadsheet uses conditional formatting, which can hide ' \
          'values. It can’t be previewed or made into a clean copy here. ' \
          'Supply a reviewed PDF or CSV instead.')
      when 'too_large_to_copy'
        _('This spreadsheet is too large to copy here.')
      when 'too_large_to_read'
        _('This spreadsheet is too large to read here.')
      end
    end

    def read_csv(bytes, max_rows: Disclosures.sheet_max_rows, max_columns: Disclosures.sheet_max_columns)
      text = utf8(bytes)
      rows = []
      total = 0
      columns = 0
      cells = { count: 0 }
      CSV.parse(text, liberal_parsing: true) do |row|
        total += 1
        columns = [columns, row.size].max
        keep(rows, row.map(&:to_s), max_rows, max_columns, cells)
      end
      Sheet.new(name: 'Table',
                rows: rows,
                total_rows: total,
                total_columns: columns,
                hidden_cells: 0,
                unformatted_cells: 0)
    rescue CSV::MalformedCSVError => e
      Rails.logger.warn("Disclosures::Sheets CSV unreadable: #{e.message}")
      raise Error::Refused, _('This CSV file can’t be read as a table.')
    end

    # UTF-8 if valid, else Windows-1252, which most UK office software writes.
    def utf8(bytes)
      text = bytes.to_s.dup.force_encoding('UTF-8')
      unless text.valid_encoding?
        text = bytes.to_s.dup.force_encoding('Windows-1252').
          encode('UTF-8', invalid: :replace, undef: :replace)
      end
      text.delete_prefix("﻿").delete("\u0002\u0003")
    end

    # nil limits: no limit, but never more than MAX_CELLS cells in the workbook.
    def keep(rows, values, max_rows, max_columns, cells)
      return if max_rows && rows.size >= max_rows

      row = max_columns ? values.first(max_columns) : values
      rows << row
      return unless max_rows.nil?

      cells[:count] += row.size
      return unless cells[:count] > MAX_CELLS

      raise Error::Refused, _('This spreadsheet is too large to copy here.')
    end
  end
end
