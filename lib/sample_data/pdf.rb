module SampleData
  # A few lines of Helvetica on A4 pages: enough for a reply's letter to be
  # read, rendered and redacted as any other PDF is.
  module PDF
    WIDTH = 595
    HEIGHT = 842
    LEFT = 72
    TOP = 770
    LEADING = 15

    module_function

    # Each page is a list of [x, y, size, text], y from the bottom.
    def build(pages)
      objects = ['<< /Type /Catalog /Pages 2 0 R >>']
      kids = pages.each_index.map { |index| "#{4 + (index * 2)} 0 R" }
      objects << "<< /Type /Pages /Kids [#{kids.join(' ')}] " \
                 "/Count #{pages.size} >>"
      objects << '<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica ' \
                 '/Encoding /WinAnsiEncoding >>'
      pages.each do |lines|
        stream = lines.map do |x, y, size, text|
          "BT /F1 #{size} Tf #{x} #{y} Td (#{escape(text)}) Tj ET"
        end.join("\n")
        objects << "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 #{WIDTH} " \
                   "#{HEIGHT}] /Resources << /Font << /F1 3 0 R >> >> " \
                   "/Contents #{objects.size + 2} 0 R >>"
        objects << "<< /Length #{stream.bytesize} >>\nstream\n#{stream}\n" \
                   'endstream'
      end
      write(objects)
    end

    # Returns [pdf_bytes, { line_text => y_baseline }] for redaction placement.
    def letter(lines)
      y = TOP
      placed = lines.map do |text|
        line = [LEFT, y, 11, text]
        y -= LEADING
        line
      end
      [build([placed]), placed.to_h { |_, at, _, text| [text, at] }]
    end

    # Converts baseline y and x bounds into top-left fractional redaction boxes.
    def box(x0, x1, baseline)
      top = HEIGHT - baseline - 12
      bottom = HEIGHT - baseline + 4
      [x0.fdiv(WIDTH), top.fdiv(HEIGHT), x1.fdiv(WIDTH), bottom.fdiv(HEIGHT)].
        map { |value| value.round(6) }
    end

    def escape(text)
      text.to_s.encode('Windows-1252', undef: :replace, replace: '?').b.
        gsub(/[\\()]/) { |char| "\\#{char}" }
    end

    def write(objects)
      out = "%PDF-1.4\n".b
      offsets = objects.each_with_index.map do |object, index|
        offset = out.bytesize
        out << "#{index + 1} 0 obj\n#{object}\nendobj\n".b
        offset
      end
      xref = out.bytesize
      out << "xref\n0 #{objects.size + 1}\n0000000000 65535 f \n"
      offsets.each { |offset| out << format("%010d 00000 n \n", offset) }
      out << "trailer\n<< /Size #{objects.size + 1} /Root 1 0 R >>\n" \
             "startxref\n#{xref}\n%%EOF\n"
      out
    end
  end
end
