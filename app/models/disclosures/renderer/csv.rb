module Disclosures
  class Renderer
    # A CSV file: one sheet.
    class Csv < Workbook
      private

      def pages(path, _dir)
        render_sheets([Sheets.read_csv(File.binread(path))])
      end

      def text_source
        'csv'
      end
    end
  end
end
