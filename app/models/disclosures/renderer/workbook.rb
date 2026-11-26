module Disclosures
  class Renderer
    # A spreadsheet: each sheet as a page of text.
    class Workbook < Kind
      def office_sections
        return [] if legacy_xls?

        [*findings_sections(Formats.ooxml?("file#{safe_extension}")), 'guard',
         'sheets']
      end

      private

      # A legacy workbook is read once LibreOffice has converted it, from the
      # file it leaves in the scratch area.
      def pages(path, _dir)
        return render_workbook(path, office_read) unless legacy_xls?

        source = LegacyOffice.to_ooxml(nil, target: 'xlsx', extension: '.xls',
                                            job: job, input_path: path)
        sections = [*findings_sections(Formats.ooxml?(source)), 'guard',
                    'sheets']
        OfficePackage::Isolated.read(sections, path: source,
                                               sheets: Sheets.limits) do |read|
          render_workbook(source, read)
        end
      end

      def render_workbook(source, read)
        office_findings(source, read, ooxml: Formats.ooxml?(source))
        render_sheets(Sheets.read_xlsx(source, read: read))
      end

      def legacy_xls?
        Formats.legacy_xls?(attachment.content_type, attachment.filename)
      end

      def render_sheets(sheets)
        sheets.each_with_index do |sheet, index|
          text = sheet.text
          truncated = sheet.truncated? || text.length > MAX_PAGE_TEXT
          cell_findings(sheet)
          add_text_page(index + 1,
                        sheet.name.presence || "Sheet #{index + 1}",
                        'sheet',
                        text.first(MAX_PAGE_TEXT),
                        text_source,
                        checked: text,
                        rows: sheet.total_rows,
                        columns: sheet.total_columns,
                        truncated: truncated)
        end
        outcome.page_count = sheets.size
      end

      # Where a page's text is said to come from (Page#text_source).
      def text_source
        'sheet'
      end

      def cell_findings(sheet)
        if sheet.hidden_cells.to_i.positive?
          label = "Sheet “#{sheet.name}”: #{sheet.hidden_cells} " \
                  "#{'cell'.pluralize(sheet.hidden_cells)} whose " \
                  'values don’t show (hidden by their number format, ' \
                  'or text the colour of the cell)'
          high = HiddenRisk.high?(sheet.hidden_values, document)
          scored(HiddenRisk::Finding.new(label, high ? :high : :low))
        end
        return unless sheet.unformatted_cells.to_i.positive?

        outcome.findings <<
          "Sheet “#{sheet.name}”: #{sheet.unformatted_cells} " \
          "#{'cell'.pluralize(sheet.unformatted_cells)} " \
          'in a number format this site can’t follow, shown here ' \
          'as stored'
      end
    end
  end
end
