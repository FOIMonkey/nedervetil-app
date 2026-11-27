module Disclosures
  class Renderer
    # A Word file or a slide deck, shown as LibreOffice prints it.
    class Office < PDF
      def office_sections
        findings_sections(Formats.ooxml?("file#{safe_extension}"))
      end

      private

      def pages(path, dir)
        office_findings(path)
        pdf = File.join(dir, 'converted.pdf')
        engine.convert_to_pdf(path, safe_extension.delete_prefix('.'), pdf)
        render_pdf(pdf, dir)
      end
    end
  end
end
