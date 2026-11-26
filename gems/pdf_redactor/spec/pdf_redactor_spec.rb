require_relative 'spec_helper'

RSpec.describe PDFRedactor do
  include AttachmentFixtures

  def rule(text, ignore_case: false)
    described_class::Rule.new(described_class.tolerant(text, ignore_case),
                              true, text.b, text)
  end

  def text_of(pdf)
    Tempfile.create(['redacted', '.pdf']) do |file|
      file.binmode
      file.write(pdf)
      file.flush
      pdf_text(file.path).gsub(/\s+/, ' ')
    end
  end

  # The file with every stream decoded, as qpdf writes it.
  def qdf_of(pdf)
    described_class.qpdf(pdf, '--qdf', '--object-streams=disable').first
  end

  def info_title(pdf)
    Tempfile.create(['redacted', '.pdf']) do |file|
      file.binmode
      file.write(pdf)
      file.flush
      `pdfinfo #{Shellwords.escape(file.path)}`[/^Title:\s*(.*)$/, 1]
    end
  end

  # A one-page PDF drawing content, with Helvetica as /F1.
  def pdf_with_streams(*contents)
    numbers = contents.each_index.map { |i| "#{i + 5} 0 R" }.join(' ')
    objects = [
      '<< /Type /Catalog /Pages 2 0 R >>',
      '<< /Type /Pages /Kids [3 0 R] /Count 1 >>',
      '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 595 842] ' \
      "/Resources << /Font << /F1 4 0 R >> >> /Contents [#{numbers}] >>",
      '<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica ' \
      '/Encoding /WinAnsiEncoding >>',
      *contents.map do |content|
        "<< /Length #{content.bytesize} >>\nstream\n#{content}\nendstream"
      end
    ]
    write(objects, root: 1, info: nil)
  end

  def page_pdf(content, font: nil, extra: [])
    font ||= '<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica ' \
             '/Encoding /WinAnsiEncoding >>'
    objects = [
      '<< /Type /Catalog /Pages 2 0 R >>',
      '<< /Type /Pages /Kids [3 0 R] /Count 1 >>',
      '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 595 842] ' \
      '/Resources << /Font << /F1 4 0 R >> >> /Contents 5 0 R >>',
      font,
      "<< /Length #{content.bytesize} >>\nstream\n#{content}\nendstream",
      *extra
    ]
    write(objects, root: 1, info: nil)
  end

  # Text in a composite font with two-byte glyph ids, as Word and Chrome
  # write it: the bytes are glyph numbers, and only the ToUnicode map says
  # which letters they are. widths: more entries for the descendant font,
  # such as its W array.
  def glyph_id_pdf(text, widths: '', encoding: 'Identity-H')
    chars = text.chars.uniq
    hex = text.chars.map { |c| format('%04X', chars.index(c) + 1) }.join
    entries = chars.each_with_index.map do |c, i|
      format('<%04X> <%04X>', i + 1, c.ord)
    end
    cmap = "/CIDInit /ProcSet findresource begin 12 dict begin begincmap\n" \
           "1 begincodespacerange <0000> <FFFF> endcodespacerange\n" \
           "#{entries.size} beginbfchar\n#{entries.join("\n")}\nendbfchar\n" \
           'endcmap CMapName currentdict /CMap defineresource pop end end'
    page_pdf(
      "BT /F1 12 Tf 72 700 Td <#{hex}> Tj ET",
      font: '<< /Type /Font /Subtype /Type0 /BaseFont /ABCDEF+Arial ' \
            "/Encoding /#{encoding} /DescendantFonts [6 0 R] " \
            '/ToUnicode 7 0 R >>',
      extra: [
        '<< /Type /Font /Subtype /CIDFontType2 /BaseFont /ABCDEF+Arial ' \
        '/CIDSystemInfo << /Registry (Adobe) /Ordering (Identity) ' \
        "/Supplement 0 >> /FontDescriptor 8 0 R /DW 500 #{widths} >>",
        "<< /Length #{cmap.bytesize} >>\nstream\n#{cmap}\nendstream",
        '<< /Type /FontDescriptor /FontName /ABCDEF+Arial /Flags 32 ' \
        '/FontBBox [0 -200 1000 900] /ItalicAngle 0 /Ascent 900 ' \
        '/Descent -200 /CapHeight 700 /StemV 80 >>'
      ]
    )
  end

  # The PDF with an incremental update that draws other text, so that its
  # first revision is still in the file.
  def updated_pdf(pdf, content)
    offset = pdf.bytesize
    update = "5 0 obj\n<< /Length #{content.bytesize} >>\nstream\n" \
             "#{content}\nendstream\nendobj\n"
    prev = pdf[/startxref\s+(\d+)/, 1]
    pdf + update + "xref\n5 1\n#{format('%010d', offset)} 00000 n \n" \
                   "trailer\n<< /Size 6 /Root 1 0 R /Prev #{prev} >>\n" \
                   "startxref\n#{offset + update.bytesize}\n%%EOF\n"
  end

  def ocr_tools?
    %w[pdftoppm tesseract magick].all? do |program|
      system('which', program, out: File::NULL, err: File::NULL)
    end
  end

  def ocr_text(pdf)
    Dir.mktmpdir do |dir|
      File.binwrite("#{dir}/in.pdf", pdf)
      png = render_pages("#{dir}/in.pdf", dir, dpi: 200).first
      IO.popen(['tesseract', png, '-'], err: File::NULL, &:read)
    end
  end

  # How much one part of two PDFs' first pages differs as a viewer draws
  # them, from 0 (the same) to 1: x0, y0, x1 and y1 are in points from the
  # bottom left of an A4 page.
  def drawn_difference(pdf, other, x0, y0, x1, y1)
    Dir.mktmpdir do |dir|
      pages = [pdf, other].each_with_index.map do |bytes, i|
        Dir.mkdir("#{dir}/#{i}")
        File.binwrite("#{dir}/#{i}/in.pdf", bytes)
        render_pages("#{dir}/#{i}/in.pdf", "#{dir}/#{i}", dpi: 72).first
      end
      part = "#{x1 - x0}x#{y1 - y0}+#{x0}+#{842 - y1}"
      magick(*pages, '-compose', 'difference', '-composite', '-crop', part,
             '+repage', '-format', '%[fx:mean]', 'info:').to_f
    end
  end

  def scanned_pdf(text)
    Dir.mktmpdir do |dir|
      File.binwrite("#{dir}/page.pdf",
                    pdf(pages: [{ texts: [{ x: 72, y: 700, text: text,
                                            size: 28 }] }]))
      png = render_pages("#{dir}/page.pdf", dir, dpi: 150).first
      magick(png, '-units', 'PixelsPerInch', '-density', '150',
             "#{dir}/scan.pdf")
      File.binread("#{dir}/scan.pdf")
    end
  end

  def ocr_pages(pdf)
    Dir.mktmpdir do |dir|
      File.binwrite("#{dir}/in.pdf", pdf)
      render_pages("#{dir}/in.pdf", dir, dpi: 200).map do |png|
        IO.popen(['tesseract', png, '-'], err: File::NULL, &:read)
      end
    end
  end

  # A 300 by 100 point grey image object of the text.
  def image_object(text)
    Dir.mktmpdir do |dir|
      File.binwrite("#{dir}/page.pdf",
                    pdf(pages: [{ size: [300, 100],
                                  texts: [{ x: 10, y: 40, text: text,
                                            size: 28 }] }]))
      png = render_pages("#{dir}/page.pdf", dir, dpi: 300).first
      raw = magick(png, '-depth', '8', '-resize', '1250x417!', 'gray:-')
      "<< /Type /XObject /Subtype /Image /Width 1250 /Height 417 " \
        "/ColorSpace /DeviceGray /BitsPerComponent 8 /Length #{raw.bytesize} " \
        ">>\nstream\n#{raw}\nendstream"
    end
  end

  def stream(content)
    "<< /Length #{content.bytesize} >>\nstream\n#{content}\nendstream"
  end

  # A PDF of pages, each a string of its page dictionary's other entries.
  # Objects 1 and 2 are the catalog and page tree, pages follow, then extra.
  def pages_pdf(pages, extra)
    kids = pages.each_index.map { |i| "#{i + 3} 0 R" }.join(' ')
    write(
      ['<< /Type /Catalog /Pages 2 0 R >>',
       "<< /Type /Pages /Kids [#{kids}] /Count #{pages.size} >>",
       *pages.map do |page|
         "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 595 842] #{page} >>"
       end,
       *extra],
      root: 1, info: nil
    )
  end

  # Text whose bytes spell "Jane Doelittle" but which a font with this
  # encoding draws as Z's.
  def zed_font
    '<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica /Encoding ' \
      '<< /Differences [68 /Z 74 /Z 97 /Z 101 /Z 105 /Z 108 /Z 110 /Z 111 /Z ' \
      '116 /Z] >> >>'
  end

  def helvetica
    '<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica ' \
      '/Encoding /WinAnsiEncoding >>'
  end

  def scan_page(image, contents)
    "/Resources << /XObject << /Im0 #{image} 0 R >> >> " \
      "/Contents #{contents} 0 R"
  end

  def scan_content = 'q 500 0 0 167 40 600 cm /Im0 Do Q'

  def name_form(font, before: '')
    body = "#{before}BT /F1 28 Tf 50 650 Td (Jane Doelittle) Tj ET"
    "<< /Type /XObject /Subtype /Form /BBox [0 0 595 842] " \
      "/Resources << /Font << /F1 #{font} 0 R >> >> " \
      "/Length #{body.bytesize} >>\nstream\n#{body}\nendstream"
  end

  describe '.redact' do
    it 'removes a rule that kerning splits in a TJ array' do
      pdf = page_pdf('BT /F1 12 Tf 72 700 Td ' \
                     '[(Minutes: J)12(ane Doe)-8(little attended.)] TJ ET')
      expect(text_of(pdf)).to include('Jane Doelittle')

      masked, report = described_class.redact(pdf, [rule('Jane Doelittle')])

      text = text_of(masked)
      expect(text).not_to include('Doelittle')
      expect(text).to include('Minutes:').and include('attended.')
      expect(report['matches']).to eq(1)
      expect(report['rules_matched']).to eq([0])
    end

    it 'puts a box saying [redacted] in place of a match' do
      pdf = page_pdf('BT /F1 12 Tf 72 700 Td (Jane Doelittle attended.) Tj ET')

      masked, report = described_class.redact(pdf, [rule('Jane Doelittle')])

      expect(text_of(masked).strip).to include('[redacted] attended.')
      expect(text_of(masked)).not_to include('Doelittle')
      expect(report['boxes']).to eq(1)
      expect(report['glyphs_censored']).to eq(14)
    end

    # The thread's redaction tool takes a digest of the masked file to know
    # it is the one an editor saw, so masking the same file again later gives
    # the same bytes: the rewrite doesn't stamp it with the time.
    it 'masks a file the same way each time, however far apart' do
      pdf = page_pdf('BT /F1 12 Tf 72 700 Td (Jane Doelittle attended.) Tj ET')

      first, = described_class.redact(pdf, [rule('Jane Doelittle')])
      sleep 2
      second, = described_class.redact(pdf, [rule('Jane Doelittle')])

      expect(second).to eq(first)
    end

    # Helvetica's shapes with a wider advance for every glyph, and a number
    # after each one in the TJ array that pulls the next back, so the letters
    # are half an em apart.
    context 'when a TJ array pulls each glyph back into the one before' do
      def pulled_back_pdf(text, advance:)
        font = '<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica ' \
               '/Encoding /WinAnsiEncoding /FirstChar 32 /LastChar 126 ' \
               "/Widths [#{Array.new(95, advance).join(' ')}] >>"
        array = text.chars.map { |c| "(#{c}) #{advance - 500}" }.join(' ')
        page_pdf("BT /F1 40 Tf 72 700 Td [#{array}] TJ ET", font: font)
      end

      it 'ends the box where the next glyph starts, so the next word shows' do
        skip 'OCR tools missing' unless ocr_tools?
        pdf = pulled_back_pdf('Jill lift', advance: 1400)
        # lift starts at the sixth glyph, 20 points apart from x = 72.
        next_word = [172, 690, 252, 730]

        masked, report = described_class.redact(pdf, [rule('Jill')])

        expect(report['glyphs_censored']).to eq(4)
        expect(drawn_difference(pdf, masked, *next_word)).to be < 0.001
      end

      it 'reads the glyphs as one line when each is pulled back by more ' \
         'than its size' do
        pdf = pulled_back_pdf('Minutes: the word stays.', advance: 2000)
        the = described_class::Rule.new(/\bthe\b/, false)

        _, report = described_class.redact(pdf, [the])

        expect(report['matches']).to eq(1)
        expect(report['glyphs_censored']).to eq(3)
      end
    end

    it 'keeps the box on a match when the next text is drawn back past it' do
      pdf = page_pdf('BT /F1 12 Tf 72 700 Td ' \
                     '[(Total ) -6000 (GBP) 7000 (12.50)] TJ ET')

      masked, = described_class.redact(pdf, [rule('GBP')])

      expect(text_of(masked)).to include('Total 12.50', '[redacted]')
    end

    it 'removes a rule from glyph id text, boxing it too' do
      pdf = glyph_id_pdf('Minutes: Jane Doelittle attended.')
      expect(text_of(pdf)).to include('Jane Doelittle')

      masked, report = described_class.redact(pdf, [rule('Jane Doelittle')])

      expect(text_of(masked)).not_to include('Doelittle')
      expect(text_of(masked)).to include('attended.')
      expect(report['glyphs_censored']).to eq(14)
      expect(report['boxes']).to eq(1)
    end

    # Poppler 25.03 draws each of these pages. The width it takes for each
    # glyph was measured with pdftotext -bbox, from where the next glyph
    # lands: the font's default, unless poppler reads the malformed array as
    # giving the glyph another, as the examples from "passes over" on say.
    context 'with a font whose widths are malformed' do
      let(:text) { 'Minutes: Jane Doelittle attended.' }

      # How far each glyph of "abcde", CIDs 1 to 5, moves the next one on, in
      # thousandths of the font's size: read from where the boxes over the
      # first, third and fifth start and end, along x or, in vertical
      # writing, y. The font's default width is 500 and its default vertical
      # advance is -1000.
      def advances(widths, encoding: 'Identity-H')
        pdf = glyph_id_pdf('abcde', widths: widths, encoding: encoding)
        masked, = described_class.redact(
          pdf, [described_class::Rule.new(/[ace]/, false)]
        )
        axis = encoding == 'Identity-V' ? 1 : 0
        boxes = qdf_of(masked)[/^q 0 g (.+?) f Q$/m, 1].lines
        ends = boxes.flat_map do |box|
          box.split(/ [ml] ?/).first(2).map { |point| point.split[axis].to_f }
        end
        ends.each_cons(2).map { |from, to| ((to - from) / 12 * 1000).round }
      end

      it 'masks the text when the W array ends after a lone CID' do
        pdf = glyph_id_pdf(text, widths: '/W [7]')

        masked, report = described_class.redact(pdf, [rule('Jane Doelittle')])

        expect(report['glyphs_censored']).to eq(14)
        expect(text_of(masked)).to include('Minutes: [redacted] attended.')
      end

      it 'masks the text when a width in the W array is not a number' do
        pdf = glyph_id_pdf(text, widths: '/W [1 [(x) 500]]')

        masked, report = described_class.redact(pdf, [rule('Jane Doelittle')])

        expect(report['glyphs_censored']).to eq(14)
        expect(text_of(masked)).to include('Minutes: [redacted] attended.')
      end

      it 'masks the text when a range in the W array has no width' do
        pdf = glyph_id_pdf(text, widths: '/W [1 3]')

        masked, report = described_class.redact(pdf, [rule('Jane Doelittle')])

        expect(report['glyphs_censored']).to eq(14)
        expect(text_of(masked)).to include('Minutes: [redacted] attended.')
      end

      it 'masks vertical text when an advance in the W2 array is not a ' \
         'number' do
        pdf = glyph_id_pdf(text, widths: '/W2 [1 [(x) 500 880]]',
                                 encoding: 'Identity-V')

        masked, report = described_class.redact(pdf, [rule('Jane Doelittle')])

        expect(report['glyphs_censored']).to eq(14)
        expect(text_of(masked)).not_to include('Doelittle')
      end

      it 'passes over a width that is not a number, so the next width is ' \
         'for the same CID' do
        expect(advances('/W [1 [(x) 900]]')).to eq([900, 500, 500, 500, 500])
        expect(advances('/W [1 [900 (x) 700]]')).
          to eq([900, 700, 500, 500, 500])
      end

      it 'passes over three vertical values that are not all numbers, so ' \
         'the next three are for the same CID' do
        ['/W2 [1 [(x) 500 880 -700 500 880]]',
         '/W2 [1 [-600 (x) 880 -700 500 880]]',
         '/W2 [1 [-600 500 (x) -700 500 880]]'].each do |widths|
          expect(advances(widths, encoding: 'Identity-V')).
            to eq([-700, -1000, -1000, -1000, -1000])
        end
      end

      it 'leaves out vertical values that are cut short at the end of a ' \
         'list' do
        expect(advances('/W2 [1 [-600 500 880 -700]]', encoding: 'Identity-V')).
          to eq([-600, -1000, -1000, -1000, -1000])
      end

      it 'leaves out a range whose width is not a number, and reads the ' \
         'entry after it' do
        expect(advances('/W [1 3 (x) 4 [900]]')).
          to eq([500, 500, 500, 900, 500])
        expect(advances('/W2 [1 3 -600 500 (x) 4 [-700 500 880]]',
                        encoding: 'Identity-V')).
          to eq([-1000, -1000, -1000, -700, -1000])
      end

      # Poppler starts again from the next value instead, which reads widths
      # as CIDs. It gives CID 2 the width 700 in the first of these, and in
      # the second it reads 900 2 [700] as a range, so CID 2 has the default.
      it 'stops reading at a value that should be a CID and is not, so the ' \
         'CIDs after it keep the default' do
        expect(advances('/W [1 [900] (x) 2 [700]]')).
          to eq([900, 500, 500, 500, 500])
        expect(advances('/W [1 (x) 900 2 [700]]')).
          to eq([500, 500, 500, 500, 500])
      end
    end

    it 'matches a rule that a line break splits' do
      pdf = page_pdf('BT /F1 12 Tf 72 700 Td (Minutes: Jane) Tj ' \
                     '0 -14 Td (Doelittle attended.) Tj ET')

      masked, report = described_class.redact(pdf, [rule('Jane Doelittle')])

      expect(text_of(masked)).not_to match(/Jane|Doelittle/)
      expect(report['matches']).to eq(1)
    end

    it 'reads one-byte codes that a ToUnicode map gives as two bytes' do
      # As Ghostscript writes a subset TrueType font's map.
      text = 'Jane Doelittle'
      chars = text.chars.uniq
      codes = text.chars.map { |c| format('%02X', chars.index(c) + 1) }.join
      names = chars.each_index.map { |i| "/g#{i + 3}" }.join(' ')
      entries = chars.each_with_index.map do |c, i|
        format('<%04X> <%04X>', i + 1, c.ord)
      end
      cmap = "1 begincodespacerange <0000> <FFFF> endcodespacerange\n" \
             "#{entries.size} beginbfchar\n#{entries.join("\n")}\nendbfchar"
      pdf = page_pdf(
        "BT /F1 12 Tf 72 700 Td <#{codes}> Tj ET",
        font: '<< /Type /Font /Subtype /TrueType /BaseFont /ABCDEF+Calibri ' \
              "/FirstChar 1 /LastChar #{chars.size} " \
              "/Widths [#{Array.new(chars.size, 500).join(' ')}] " \
              "/Encoding << /Differences [1 #{names}] >> /ToUnicode 6 0 R >>",
        extra: ["<< /Length #{cmap.bytesize} >>\nstream\n#{cmap}\nendstream"]
      )

      _, report = described_class.redact(pdf, [rule('Jane Doelittle')])

      expect(report['matches']).to eq(1)
    end

    it 'ignores case when the rule does' do
      pdf = page_pdf('BT /F1 12 Tf 72 700 Td (JANE DOELITTLE) Tj ET')

      masked, = described_class.redact(
        pdf, [rule('Jane Doelittle', ignore_case: true)]
      )

      expect(text_of(masked)).not_to include('DOELITTLE')
    end

    it 'censors the document information' do
      pdf = pdf(pages: [letter_page(secret: 'Nothing here')],
                info: { Title: 'Notes on Jane Doelittle' })

      masked, report = described_class.redact(pdf, [rule('Jane Doelittle')])

      expect(info_title(masked)).to eq('Notes on [redacted]')
      expect(report['text_strings_censored']).to eq(1)
    end

    it 'covers all of an email address' do
      pdf = page_pdf('BT /F1 12 Tf 72 700 Td ' \
                     '(Write to jane@example.org.) Tj ET')
      email = described_class::Rule.new(/\S+@\S+\.org/, false)

      masked, = described_class.redact(pdf, [email])

      expect(text_of(masked).strip).to include('Write to [redacted]')
      expect(text_of(masked)).not_to include('example')
    end

    it 'labels a box on a page whose streams are joined' do
      pdf = pdf_with_streams('BT /F1 12 Tf 72 700 Td',
                             '(Jane Doelittle attended.) Tj ET')

      masked, report = described_class.redact(pdf, [rule('Jane Doelittle')])

      expect(report['boxes']).to eq(1)
      expect(text_of(masked)).to include('[redacted]', 'attended.')
      expect(text_of(masked)).not_to include('Doelittle')
    end

    it 'keeps the page’s own fonts when it adds the label’s' do
      pdf = page_pdf('BT /F1 12 Tf 72 700 Td (Jane Doelittle attended.) Tj ' \
                     '0 -14 Td (Other words stay.) Tj ET')

      masked, = described_class.redact(pdf, [rule('Jane Doelittle')])

      expect(text_of(masked)).to include('attended.', 'Other words stay.')
    end

    it 'still applies a rule written in content-stream syntax' do
      pdf = page_pdf('BT /F1 12 Tf 72 700 Td (Jane Doelittle attended.) Tj ET')
      pasted = described_class::Rule.new(/(?!)/, false, 'Jane Doelittle'.b)

      masked, report = described_class.redact(pdf, [pasted])

      expect(text_of(masked)).not_to include('Doelittle')
      expect(report['legacy_rules_matched']).to eq([0])
      expect(report['rules_matched']).to eq([0])
    end

    it 'says whether it changed the content' do
      pdf = page_pdf('BT /F1 12 Tf 72 700 Td (Jane Doelittle attended.) Tj ET')

      _, matched = described_class.redact(pdf, [rule('Jane Doelittle')])
      _, unmatched = described_class.redact(pdf, [rule('Someone Else')])

      expect(matched['changed']).to be(true)
      expect(unmatched['changed']).to be(false)
    end

    it 'raises PasswordRequired for a PDF it cannot open' do
      locked = encrypted_pdf(pdf(pages: [letter_page(secret: 'Jane')]))
      expect { described_class.redact(locked, [rule('Jane')]) }.
        to raise_error(described_class::PasswordRequired)
    end

    # A file whose attached files alone are encrypted (/EFF, with the
    # password asked for only when one is opened): readers show its pages
    # without a password, but qpdf needs one for the whole file.
    def attachments_only_encrypted(content)
      encrypt = '<< /Filter /Standard /V 4 /R 4 /Length 128 /CF << /StdCF ' \
                '<< /CFM /AESV2 /AuthEvent /EFOpen /Length 16 >> >> ' \
                '/StmF /Identity /StrF /Identity /EFF /StdCF ' \
                "/O <#{'11' * 32}> /U <#{'22' * 32}> /P -4 >>"
      with_encrypt(content, encrypt)
    end

    def with_encrypt(content, encrypt)
      page_pdf(content, extra: [encrypt]).
        sub('/Root 1 0 R',
            "/Root 1 0 R /Encrypt 6 0 R /ID [<#{'ab' * 16}> <#{'ab' * 16}>]")
    end

    it 'raises PasswordRequired for a PDF whose attached files alone need ' \
       'the password, though its pages open without one' do
      pdf = attachments_only_encrypted(
        'BT /F1 12 Tf 72 700 Td (Jane Doelittle) Tj ET'
      )
      expect(text_of(pdf)).to include('Jane Doelittle')

      expect { described_class.redact(pdf, [rule('Jane Doelittle')]) }.
        to raise_error(described_class::PasswordRequired)
    end

    it 'serves as it came a PDF whose pages and attachments all need the ' \
       'password' do
      encrypt = '<< /Filter /Standard /V 4 /R 4 /Length 128 /CF << /StdCF ' \
                '<< /CFM /AESV2 /Length 16 >> >> /StmF /StdCF /StrF /StdCF ' \
                "/EFF /StdCF /O <#{'11' * 32}> /U <#{'22' * 32}> /P -4 >>"
      pdf = with_encrypt('BT /F1 12 Tf 72 700 Td (Jane Doelittle) Tj ET',
                         encrypt)

      expect { described_class.redact(pdf, [rule('Jane Doelittle')]) }.
        to raise_error(described_class::PasswordRequired)
    end

    it 'raises if a step after opening it needs a password (a fault)' do
      allow(described_class).to receive(:qpdf).and_call_original
      allow(described_class).to receive(:qpdf).
        with(anything, *described_class::Redactor::COMPRESS).
        and_raise(described_class::PasswordRequired)
      pdf = page_pdf('BT /F1 12 Tf 72 700 Td (Jane Doelittle) Tj ET')

      expect { described_class.redact(pdf, [rule('Jane Doelittle')]) }.
        to raise_error(described_class::Error, /a step after opening/)
    end

    it 'drops earlier revisions, even when nothing matches' do
      original = page_pdf('BT /F1 12 Tf 72 700 Td (Jane Doelittle) Tj ET')
      pdf = updated_pdf(original, 'BT /F1 12 Tf 72 700 Td (Nothing here) Tj ET')
      expect(pdf).to include('Jane Doelittle')

      masked, report = described_class.redact(pdf, [rule('Someone Else')])

      expect(qdf_of(masked)).not_to include('Doelittle')
      expect(text_of(masked)).to include('Nothing here')
      expect(report['matches']).to eq(0)
    end

    it 'has qpdf decode every stream when a filter is not one it reads' do
      content = 'BT /F1 12 Tf 72 700 Td (Jane Doelittle attended.) Tj ET'
      hex = "#{content.unpack1('H*')}>"
      pdf = write(
        ['<< /Type /Catalog /Pages 2 0 R >>',
         '<< /Type /Pages /Kids [3 0 R] /Count 1 >>',
         '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 595 842] ' \
         '/Resources << /Font << /F1 4 0 R >> >> /Contents 5 0 R >>',
         '<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>',
         "<< /Length #{hex.bytesize} /Filter /ASCIIHexDecode >>\n" \
         "stream\n#{hex}\nendstream"],
        root: 1, info: nil
      )

      masked, report = described_class.redact(pdf, [rule('Jane Doelittle')])

      expect(text_of(masked)).not_to include('Doelittle')
      expect(report['full_decode']).to be(true)
    end

    it 'counts a scanned page it was not asked to read' do
      skip 'OCR tools missing' unless ocr_tools?

      masked, report = described_class.redact(scanned_pdf('Jane Doelittle'),
                                              [rule('Jane Doelittle')])

      expect(masked).to start_with('%PDF')
      expect(report['image_only_pages_not_read']).to eq(1)
      expect(report['ocr_pages']).to eq(0)
    end

    it 'reads a scanned page with OCR and swaps it for a picture of itself' do
      skip 'OCR tools missing' unless ocr_tools?

      masked, report = described_class.redact(
        scanned_pdf('Minutes: Jane Doelittle attended.'),
        [rule('Jane Doelittle')], ocr: true
      )

      expect(report['ocr_matches']).to eq(1)
      expect(report['pages_rasterized']).to eq(1)
      # Still a scan, with no text layer: only OCR reads it.
      expect(text_of(masked).strip).to be_empty
      expect(ocr_text(masked)).not_to include('Doelittle')
      expect(ocr_text(masked)).to include('attended')
    end

    # A searchable scan: a picture of the words, and the same words over it
    # in text rendering mode 3, which draws nothing. Taking the name out of
    # the text leaves it in the picture.
    context 'with a match in the hidden text over a picture' do
      let(:picture) { 'q 300 0 0 100 40 600 cm /Im0 Do Q' }

      let(:hidden_text) do
        'BT 3 Tr /F1 28 Tf 50 640 Td (Dear Jane Doelittle) Tj ET'
      end

      def form(resources, content)
        "<< /Type /XObject /Subtype /Form /BBox [0 0 595 842] " \
          "/Resources << #{resources} >> /Length #{content.bytesize} >>\n" \
          "stream\n#{content}\nendstream"
      end

      def expect_name_boxed_in_picture(pdf, pages: 1)
        expect(text_of(pdf)).to include('Jane Doelittle')

        masked, report = described_class.redact(pdf, [rule('Jane Doelittle')])

        expect(report['matches_in_invisible_text']).to eq(pages)
        expect(report['boxes_over_images']).to eq(pages)
        expect(report['pages_rasterized']).to eq(pages)
        expect(text_of(masked)).not_to include('Doelittle')
        seen = ocr_pages(masked)
        expect(seen).to all(include('Dear'))
        expect(seen.join).not_to include('Doelittle')
      end

      before { skip 'OCR tools missing' unless ocr_tools? }

      it 'boxes the name in the picture and swaps the page for a picture of ' \
         'itself' do
        pdf = pages_pdf(
          ['/Resources << /XObject << /Im0 5 0 R >> /Font << /F1 6 0 R >> >> ' \
           '/Contents 4 0 R'],
          [stream("#{picture} #{hidden_text}"),
           image_object('Dear Jane Doelittle'), helvetica]
        )

        expect_name_boxed_in_picture(pdf)
      end

      it 'boxes it when a form draws the picture' do
        pdf = pages_pdf(
          ['/Resources << /XObject << /Fm0 5 0 R >> /Font << /F1 7 0 R >> >> ' \
           '/Contents 4 0 R'],
          [stream("/Fm0 Do #{hidden_text}"),
           form('/XObject << /Im0 6 0 R >>', picture),
           image_object('Dear Jane Doelittle'), helvetica]
        )

        expect_name_boxed_in_picture(pdf)
      end

      it 'boxes it when the picture is two forms deep' do
        pdf = pages_pdf(
          ['/Resources << /XObject << /Fm0 5 0 R >> /Font << /F1 8 0 R >> >> ' \
           '/Contents 4 0 R'],
          [stream("/Fm0 Do #{hidden_text}"),
           form('/XObject << /Fm1 6 0 R >>', '/Fm1 Do'),
           form('/XObject << /Im0 7 0 R >>', picture),
           image_object('Dear Jane Doelittle'), helvetica]
        )

        expect_name_boxed_in_picture(pdf)
      end

      it 'boxes it on each page that draws the picture’s form' do
        page = '/Resources << /XObject << /Fm0 7 0 R >> /Font << /F1 9 0 R ' \
               '>> >> /Contents %d 0 R'
        pdf = pages_pdf(
          [page % 5, page % 6],
          [stream("/Fm0 Do #{hidden_text}"), stream("/Fm0 Do #{hidden_text}"),
           form('/XObject << /Im0 8 0 R >>', picture),
           image_object('Dear Jane Doelittle'), helvetica]
        )

        expect_name_boxed_in_picture(pdf, pages: 2)
      end
    end

    context 'with the name outside the page content' do
      let(:secret) { 'Jane Doelittle' }

      # True if the text is anywhere in the file once qpdf has decoded its
      # streams: as written or in hex, in PDFDocEncoding or UTF-16BE.
      def leaks?(pdf, text)
        qdf = qdf_of(pdf)
        hex = qdf.downcase
        [text.b, text.encode('UTF-16BE').b].any? do |form|
          qdf.include?(form) || hex.include?(form.unpack1('H*'))
        end
      end

      def flate_stream(dict, data)
        data = Zlib::Deflate.deflate(data)
        "<< #{dict} /Filter /FlateDecode /Length #{data.bytesize} >>\n" \
          "stream\n".b + data + "\nendstream".b
      end

      def resources_with_secret
        '<< /Font << /F1 4 0 R >> /Properties ' \
          "<< /MC0 << /ActualText (#{secret}) >> >> >>"
      end

      def marked_secret(size = 12)
        "/Span /MC0 BDC BT /F1 #{size} Tf 72 700 Td (#{secret} attended.) " \
          'Tj ET EMC'
      end

      # The labelled page's resources are in its parent (inherited), or in
      # an object of their own (indirect): not in the page dictionary.
      def labelled_pdf(how)
        resources = "/Resources #{resources_with_secret}"
        inherited = how == :inherited ? resources : ''
        own = how == :indirect ? '/Resources 6 0 R' : ''
        write(
          ['<< /Type /Catalog /Pages 2 0 R >>',
           "<< /Type /Pages /Kids [3 0 R] /Count 1 #{inherited} >>",
           '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 595 842] ' \
           "#{own} /Contents 5 0 R >>",
           helvetica, stream(marked_secret),
           *(how == :indirect ? [resources_with_secret] : [])],
          root: 1, info: nil
        )
      end

      { 'inherits' => :inherited, 'refers to' => :indirect }.each do |verb, how|
        it "raises rather than copy a censored string in the " \
           "resources a labelled page #{verb}" do
          pdf = labelled_pdf(how)
          expect(leaks?(pdf, secret)).to be(true)

          expect { described_class.redact(pdf, [rule(secret)]) }.
            to raise_error(described_class::Error, /would copy censored text/)
        end

        it "labels a page whose resources it #{verb} have nothing censored" do
          masked, report = described_class.redact(labelled_pdf(how),
                                                  [rule('attended')])

          expect(report['boxes']).to eq(1)
          expect(text_of(masked)).to include('[redacted]')
          expect(text_of(masked)).not_to include('attended')
        end
      end

      it 'raises rather than write a stream dictionary over a ' \
         'censored string' do
        # A compressed form: masking its text writes the stream decoded, and
        # its dictionary again without /Filter.
        form = flate_stream('/Type /XObject /Subtype /Form ' \
                            '/BBox [0 0 595 842] ' \
                            "/Resources #{resources_with_secret}",
                            marked_secret(28))
        pdf = write(
          ['<< /Type /Catalog /Pages 2 0 R >>',
           '<< /Type /Pages /Kids [3 0 R] /Count 1 >>',
           '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 595 842] ' \
           '/Resources << /XObject << /Fm0 6 0 R >> >> /Contents 5 0 R >>',
           helvetica, stream('/Fm0 Do'), form],
          root: 1, info: nil
        )
        expect(leaks?(pdf, secret)).to be(true)

        expect { described_class.redact(pdf, [rule(secret)]) }.
          to raise_error(described_class::Error, /two edits overlap/)
      end

      # An attached text file, with or without /Type /EmbeddedFile, which
      # ISO 32000-1 Table 44 makes optional.
      def attachment_pdf(type)
        write(
          ['<< /Type /Catalog /Pages 2 0 R /Names << /EmbeddedFiles ' \
           '<< /Names [(a.txt) << /Type /Filespec /F (a.txt) ' \
           '/EF << /F 5 0 R >> >>] >> >> >>',
           '<< /Type /Pages /Kids [3 0 R] /Count 1 >>',
           '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 595 842] ' \
           '/Resources << >> /Contents 4 0 R >>',
           stream('q Q'),
           flate_stream(type, "Minutes: #{secret} attended.")],
          root: 1, info: nil
        )
      end

      it 'censors an attached file' do
        pdf = attachment_pdf('/Type /EmbeddedFile')
        expect(leaks?(pdf, secret)).to be(true)

        masked, report = described_class.redact(pdf, [rule(secret)])

        expect(report['attached_text_censored']).to eq(1)
        expect(leaks?(masked, secret)).to be(false)
      end

      def attached_file(pdf, key)
        Tempfile.create(['outer', '.pdf']) do |file|
          file.binmode
          file.write(pdf)
          file.flush
          IO.popen(['qpdf', "--show-attachment=#{key}", file.path], &:read)
        end
      end

      it 'masks an attached PDF that says it is metadata' do
        inner = described_class.qpdf(
          page_pdf("BT /F1 12 Tf 72 700 Td (#{secret} attended.) Tj ET"),
          '--compress-streams=y'
        ).first
        attached = "<< /Type /Metadata /Subtype /XML /Length " \
                   "#{inner.bytesize} >>\nstream\n".b + inner + "\nendstream".b
        pdf = write(
          ['<< /Type /Catalog /Pages 2 0 R /Names << /EmbeddedFiles ' \
           '<< /Names [(a.pdf) << /Type /Filespec /F (a.pdf) ' \
           '/EF << /F 5 0 R >> >>] >> >> >>',
           '<< /Type /Pages /Kids [3 0 R] /Count 1 >>',
           '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 595 842] ' \
           '/Resources << >> /Contents 4 0 R >>',
           stream('q Q'), attached],
          root: 1, info: nil
        )
        expect(leaks?(attached_file(pdf, 'a.pdf'), secret)).to be(true)

        masked, report = described_class.redact(pdf, [rule(secret)])

        expect(report['attached_pdfs_censored']).to eq(1)
        expect(leaks?(attached_file(masked, 'a.pdf'), secret)).to be(false)
      end

      it 'masks a file whose attached PDF needs a password, leaving that ' \
         'PDF as it came' do
        locked = encrypted_pdf(page_pdf('BT /F1 12 Tf 72 700 Td (Other) Tj ET'))
        attached = "<< /Type /EmbeddedFile /Length #{locked.bytesize} >>\n" \
                   "stream\n".b + locked + "\nendstream".b
        pdf = write(
          ['<< /Type /Catalog /Pages 2 0 R /Names << /EmbeddedFiles ' \
           '<< /Names [(a.pdf) << /Type /Filespec /F (a.pdf) ' \
           '/EF << /F 5 0 R >> >>] >> >> >>',
           '<< /Type /Pages /Kids [3 0 R] /Count 1 >>',
           '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 595 842] ' \
           '/Resources << /Font << /F1 6 0 R >> >> /Contents 4 0 R >>',
           stream(marked_secret), attached, helvetica],
          root: 1, info: nil
        )
        expect { described_class.redact(locked, []) }.
          to raise_error(described_class::PasswordRequired)

        masked, report = described_class.redact(pdf, [rule(secret)])

        expect(leaks?(masked, secret)).to be(false)
        expect(qdf_of(masked)).to include(locked)
        expect(report['unmasked_parts']).
          to match([/\Aattached PDF \(object \d+\) needs a password\z/])
      end

      # Places Redactor never reads, which the final scan reads instead: a
      # rule that still matches there stops the file going public as it is.
      def bare_page_pdf(catalog: '', page: '', extra: [])
        write(
          ["<< /Type /Catalog /Pages 2 0 R #{catalog} >>",
           '<< /Type /Pages /Kids [3 0 R] /Count 1 >>',
           "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 595 842] #{page} >>",
           *extra],
          root: 1, info: nil
        )
      end

      def scan_after_masking(pdf, rules)
        masked, = described_class.redact(pdf, rules)
        -> { described_class::FinalScan.check!(masked, rules) }
      end

      def expect_final_scan_to_withhold(pdf, where)
        expect(leaks?(pdf, secret)).to be(true)

        expect(&scan_after_masking(pdf, [rule(secret)])).
          to raise_error(described_class::Error,
                         /still matches in #{where} after masking/) { |e|
            expect(e.message).not_to include('Doelittle')
          }
      end

      it 'finds the name in a direct /Info in its trailer' do
        pdf = bare_page_pdf.sub('/Root 1 0 R',
                                "/Root 1 0 R /Info << /Title (#{secret}) >>")
        expect_final_scan_to_withhold(pdf, 'the trailer')
      end

      it 'finds the name in a signature' do
        pdf = bare_page_pdf(
          catalog: '/AcroForm << /Fields [4 0 R] /SigFlags 3 >>',
          page: '/Annots [4 0 R]',
          extra: ['<< /Type /Annot /Subtype /Widget /FT /Sig /T (Sig1) ' \
                  '/Rect [0 0 0 0] /P 3 0 R /V 5 0 R >>',
                  "<< /Type /Sig /Filter /Adobe.PPKLite /Name (#{secret}) " \
                  '/ByteRange [0 0 0 0] /Contents <00> >>']
        )
        expect_final_scan_to_withhold(pdf, 'object \d+')
      end

      it 'finds the name in an XFA form' do
        pdf = bare_page_pdf(
          catalog: '/AcroForm << /Fields [] /XFA 4 0 R >>',
          extra: [flate_stream('', "<xdp><field>#{secret}</field></xdp>")]
        )
        expect_final_scan_to_withhold(pdf, 'object \d+')
      end

      it 'finds the name in a JavaScript stream' do
        pdf = bare_page_pdf(
          catalog: '/Names << /JavaScript << /Names [(a) << /S /JavaScript ' \
                   '/JS 4 0 R >>] >> >>',
          extra: [flate_stream('', "app.alert('#{secret}');")]
        )
        expect_final_scan_to_withhold(pdf, 'object \d+')
      end

      it 'finds the name drawn in a pattern, in hex' do
        # The pattern is a content stream that Redactor doesn't read, and in
        # hex its bytes don't spell the name.
        hex = secret.unpack1('H*')
        pattern = flate_stream(
          '/PatternType 1 /PaintType 1 /TilingType 1 /BBox [0 0 595 842] ' \
          '/XStep 595 /YStep 842 /Resources << /Font << /F1 5 0 R >> >>',
          "BT /F1 12 Tf 72 700 Td <#{hex}> Tj ET"
        )
        pdf = bare_page_pdf(
          page: '/Resources << /Pattern << /P0 4 0 R >> >> /Contents 6 0 R',
          extra: [pattern, helvetica,
                  stream('/Pattern cs /P0 scn 0 0 595 842 re f')]
        )
        expect_final_scan_to_withhold(pdf, 'object \d+')
      end

      it 'finds the name in JavaScript in PDFDocEncoding' do
        # One accented letter, so the stream isn't UTF-8.
        script = "app.alert('#{secret}, caf".b + "\xE9".b + "');".b
        pdf = bare_page_pdf(
          catalog: '/Names << /JavaScript << /Names [(a) << /S /JavaScript ' \
                   '/JS 4 0 R >>] >> >>',
          extra: [flate_stream('', script)]
        )
        expect_final_scan_to_withhold(pdf, 'object \d+')
      end

      it "finds Illustrator's compressed data" do
        data = '%AI12_CompressedData'.b + Zlib::Deflate.deflate(secret)
        pdf = bare_page_pdf(
          page: '/PieceInfo << /Illustrator << /Private 4 0 R >> >>',
          extra: [flate_stream('', data)]
        )

        expect(&scan_after_masking(pdf, [rule(secret)])).
          to raise_error(described_class::Error,
                         /Illustrator's compressed data, which is not read/)
      end

      it 'finds a zip that only the trailer points to' do
        # As a hybrid PDF's /AdditionalStreams can, without /EF or /Type.
        zip = "PK\x03\x04\x14\x00\x00\x00mimetype".b +
              'application/vnd.oasis.opendocument.text'.b
        pdf = bare_page_pdf(extra: [flate_stream('', zip)]).sub(
          '/Root 1 0 R',
          '/Root 1 0 R /AdditionalStreams ' \
          '[/application#2fvnd.oasis.opendocument.text 4 0 R]'
        )

        expect(&scan_after_masking(pdf, [rule(secret)])).
          to raise_error(described_class::Error, /holds a zip file/)
      end

      it 'reads bytes that are not text for literal rules, not patterns' do
        email = described_class::Rule.new(/\S+@\S+\.org/, false)
        binary = ->(text) { "\x00\x01\x02#{text}\x00\xFF".b }
        with_address = bare_page_pdf(
          catalog: '/Extra 4 0 R',
          extra: [flate_stream('', binary.call('jane@example.org'))]
        )
        with_name = bare_page_pdf(
          catalog: '/Extra 4 0 R',
          extra: [flate_stream('', binary.call(secret))]
        )

        expect(&scan_after_masking(with_address, [rule(secret), email])).
          not_to raise_error
        expect(&scan_after_masking(with_name, [rule(secret), email])).
          to raise_error(described_class::Error, /still matches in object/)
      end

      def javascript_catalog
        '/Names << /JavaScript << /Names [(a) << /S /JavaScript ' \
          '/JS 4 0 R >>] >> >>'
      end

      it 'reads a stream that a stray /FontFile points to' do
        pdf = bare_page_pdf(
          catalog: "#{javascript_catalog} /Extra << /FontFile 4 0 R >>",
          extra: [flate_stream('', "app.alert('#{secret}');")]
        )
        expect_final_scan_to_withhold(pdf, 'object \d+')
      end

      it 'reads a stream marked as a picture that is reached as text' do
        pdf = bare_page_pdf(
          catalog: javascript_catalog,
          extra: [flate_stream('/Type /XObject /Subtype /Image /Width 1 ' \
                               '/Height 1 /ColorSpace /DeviceGray ' \
                               '/BitsPerComponent 8',
                               "app.alert('#{secret}');")]
        )
        expect_final_scan_to_withhold(pdf, 'object \d+')
      end

      def picture_pdf(filter, data)
        picture = "<< /Type /XObject /Subtype /Image /Width 1 /Height 1 " \
                  '/ColorSpace /DeviceGray /BitsPerComponent 8 ' \
                  "/Filter /#{filter} /Length #{data.bytesize} >>\n" \
                  "stream\n".b + data + "\nendstream".b
        bare_page_pdf(
          page: '/Resources << /XObject << /Im0 4 0 R >> >> /Contents 5 0 R',
          extra: [picture, stream('q 10 0 0 10 0 0 cm /Im0 Do Q')]
        )
      end

      def box(type, data) = [8 + data.bytesize].pack('N') + type + data

      # A picture's samples with a PNG predictor, which the scan doesn't
      # decode, as it reads no text from such a picture.
      it 'reads a file with a PNG-predictor picture' do
        rows = Zlib::Deflate.deflate("\x00\xFF\x00\x00\x00\xFF".b)
        pdf = picture_pdf('FlateDecode /DecodeParms << /Predictor 15 ' \
                          '/Colors 1 /BitsPerComponent 8 /Columns 2 >>', rows)

        expect { described_class::FinalScan.check!(pdf, [rule(secret)]) }.
          not_to raise_error
      end

      it 'finds the name in a JPEG 2000 XML box' do
        jp2 = box('jP  ', "\r\n\x87\n".b) + box('ftyp', 'jp2 ' * 3) +
              box('xml ', "<x>#{secret}</x>") +
              box('jp2c', "\xFF\x4F\xFF\xD9".b)
        expect_final_scan_to_withhold(picture_pdf('JPXDecode', jp2.b),
                                      'object \d+')
      end

      comment = "\xFF\xFE".b + [2 + 14].pack('n') + 'Jane Doelittle'
      {
        'in a comment after the first scan' => [comment, ''],
        'after its end' => ['', 'Minutes: Jane Doelittle']
      }.each do |where, (inside, after)|
        it "finds the name in a JPEG #{where}" do
          jpeg = "\xFF\xD8\xFF\xDA\x00\x08\x01\x01\x00\x00\x3F\x00\x12\x34".b +
                 inside.b + "\x56\xFF\xD9".b + after.b
          expect_final_scan_to_withhold(picture_pdf('DCTDecode', jpeg),
                                        'object \d+')
        end
      end

      it 'finds the name in UTF-16 with no byte order mark, ' \
         'as Exif keeps an author' do
        # Exif with a thumbnail: mostly bytes that aren't NUL, so Redactor
        # doesn't read it as UTF-16.
        exif = "Exif\x00\x00".b + ((1..255).to_a * 12).pack('C*') +
               secret.encode('UTF-16LE').b
        jpeg = "\xFF\xD8\xFF\xE1".b + [2 + exif.bytesize].pack('n') + exif +
               "\xFF\xDA\x00\x08\x01\x01\x00\x00\x3F\x00\x12\x34\xFF\xD9".b

        pdf = picture_pdf('DCTDecode', jpeg)

        expect(&scan_after_masking(pdf, [rule(secret)])).
          to raise_error(described_class::Error, /still matches in object/)
      end

      {
        'a zip file' => "PK\x03\x04\x14\x00",
        'an OLE file' => "\xD0\xCF\x11\xE0\xA1\xB1\x1A\xE1",
        'a 7-Zip file' => "7z\xBC\xAF\x27\x1C",
        'a RAR file' => "Rar!\x1A\x07\x00",
        'gzip data' => "\x1F\x8B\x08\x00\x00\x00\x00\x00\x00\x03"
      }.each do |kind, start|
        it "finds #{kind} inside a stream" do
          pdf = bare_page_pdf(
            catalog: '/Extra 4 0 R',
            extra: [flate_stream('', "Some header bytes. #{start}rest".b)]
          )

          expect(&scan_after_masking(pdf, [rule(secret)])).
            to raise_error(described_class::Error, /holds #{kind}/)
        end
      end

      it 'reads a stream left encoded as a picture that is not one' do
        script = "app.alert('#{secret}');"
        pdf = bare_page_pdf(
          catalog: javascript_catalog,
          extra: ["<< /Filter /DCTDecode /Length #{script.bytesize} >>\n" \
                  "stream\n#{script}\nendstream"]
        )
        expect_final_scan_to_withhold(pdf, 'object \d+')
      end

      # A censor rule's raw-byte pass already x's its text in a content
      # stream, inline images too. A mask, or NameMask's names, has none.
      it 'finds the name in an inline JPEG' do
        comment = "\xFF\xFE".b + [2 + secret.bytesize].pack('n') + secret
        jpeg = "\xFF\xD8".b + comment +
               "\xFF\xDA\x00\x08\x01\x01\x00\x00\x3F\x00\x12\x34\xFF\xD9".b
        content = 'q 10 0 0 10 0 0 cm BI /W 1 /H 1 /CS /G /BPC 8 /F /DCT ' \
                  'ID '.b + jpeg + "\nEI Q".b
        pdf = bare_page_pdf(page: '/Contents 4 0 R', extra: [stream(content)])
        decoded = described_class::Rule.new(
          described_class.tolerant(secret, false), true, nil, secret
        )

        expect(&scan_after_masking(pdf, [decoded])).
          to raise_error(described_class::Error, /still matches in object/)
      end

      it 'finds the name a page still shows, read by its fonts' do
        # As if Redactor had missed the glyphs: the box is drawn, but they
        # stay under it.
        allow_any_instance_of(described_class::Redactor).
          to receive(:edited_stream) { |_, data, _| data }
        decoded = described_class::Rule.new(
          described_class.tolerant(secret, false), true, nil, secret
        )
        pdf = page_pdf("BT /F1 12 Tf 72 700 Td (#{secret} attended.) Tj ET")

        expect(&scan_after_masking(pdf, [decoded])).
          to raise_error(described_class::Error,
                         /still matches in the text pdftotext reads/)
      end

      # As if Redactor had missed the glyphs: the box is drawn, but they stay
      # under it, so only the final scan's pdftotext can find them.
      def missing_removal
        allow_any_instance_of(described_class::Redactor).
          to receive(:edited_stream) { |_, data, _| data }
        described_class::Rule.new(
          described_class.tolerant(secret, false), true, nil, secret
        )
      end

      it 'reads the text in a layer that is off by default' do
        decoded = missing_removal
        pdf = bare_page_pdf(
          catalog: '/OCProperties << /OCGs [6 0 R] /D << /OFF [6 0 R] >> >>',
          page: '/Resources << /Font << /F1 4 0 R >> /Properties ' \
                '<< /oc1 6 0 R >> >> /Contents 5 0 R',
          extra: [helvetica,
                  stream("/OC /oc1 BDC BT /F1 12 Tf 72 700 Td (#{secret}) " \
                         'Tj ET EMC'),
                  '<< /Type /OCG /Name (Layer) >>']
        )

        expect(&scan_after_masking(pdf, [decoded])).
          to raise_error(described_class::Error,
                         /still matches in the text pdftotext reads/)
      end

      it 'reads the text drawn off the page' do
        decoded = missing_removal
        pdf = bare_page_pdf(
          page: '/Resources << /Font << /F1 4 0 R >> >> /Contents 5 0 R',
          extra: [helvetica,
                  stream("BT /F1 12 Tf -400 700 Td (#{secret}) Tj ET")]
        )

        expect(&scan_after_masking(pdf, [decoded])).
          to raise_error(described_class::Error,
                         /still matches in the text pdftotext reads/)
      end

      it 'reads the text drawn far off the page' do
        decoded = missing_removal
        pdf = bare_page_pdf(
          page: '/Resources << /Font << /F1 4 0 R >> >> /Contents 5 0 R',
          extra: [helvetica,
                  stream("BT /F1 12 Tf 150000 700 Td (#{secret}) Tj ET")]
        )

        expect(&scan_after_masking(pdf, [decoded])).
          to raise_error(described_class::Error,
                         /still matches in the text pdftotext reads/)
      end

      # qpdf gives the page a Letter box ("MediaBox is undefined; setting to
      # letter"), which the copy makes big.
      it 'reads the text off a page that has no /MediaBox' do
        decoded = missing_removal
        pdf = write(
          ['<< /Type /Catalog /Pages 2 0 R >>',
           '<< /Type /Pages /Kids [3 0 R] /Count 1 >>',
           '<< /Type /Page /Parent 2 0 R /Resources << /Font << /F1 4 0 R >> ' \
           '>> /Contents 5 0 R >>',
           helvetica, stream("BT /F1 12 Tf 1000 700 Td (#{secret}) Tj ET")],
          root: 1, info: nil
        )

        expect(&scan_after_masking(pdf, [decoded])).
          to raise_error(described_class::Error,
                         /still matches in the text pdftotext reads/)
      end

      it 'fails if pdftotext reads less of the revealing copy' do
        # As if poppler read the copy oddly, as it does a page box of 1e30.
        allow_any_instance_of(described_class::FinalScan).
          to receive(:revealed).and_return(bare_page_pdf)
        pdf = page_pdf('BT /F1 12 Tf 72 700 Td (Other words) Tj ET')

        expect(&scan_after_masking(pdf, [rule(secret)])).
          to raise_error(described_class::Error, /read less text/)
      end

      it 'reads the text of an annotation that its flags hide' do
        decoded = missing_removal
        # In a font whose codes are glyph numbers, so only a reader that goes
        # through its ToUnicode map finds the name.
        chars = secret.chars.uniq
        hex = secret.chars.map { |c| format('%04X', chars.index(c) + 1) }.join
        entries = chars.each_with_index.map do |c, i|
          format('<%04X> <%04X>', i + 1, c.ord)
        end
        cmap = '/CIDInit /ProcSet findresource begin 12 dict begin ' \
               "begincmap\n1 begincodespacerange <0000> <FFFF> " \
               "endcodespacerange\n#{entries.size} beginbfchar\n" \
               "#{entries.join("\n")}\nendbfchar\nendcmap CMapName " \
               'currentdict /CMap defineresource pop end end'
        appearance = "BT /F1 12 Tf 10 50 Td <#{hex}> Tj ET"
        pdf = bare_page_pdf(
          page: '/Annots [4 0 R]',
          extra: [
            '<< /Type /Annot /Subtype /FreeText /Rect [50 600 400 700] /F 2 ' \
            '/AP << /N 5 0 R >> >>',
            '<< /Type /XObject /Subtype /Form /BBox [0 0 350 100] ' \
            '/Resources << /Font << /F1 6 0 R >> >> ' \
            "/Length #{appearance.bytesize} >>\nstream\n#{appearance}\n" \
            'endstream',
            '<< /Type /Font /Subtype /Type0 /BaseFont /ABCDEF+Arial ' \
            '/Encoding /Identity-H /DescendantFonts [7 0 R] ' \
            '/ToUnicode 8 0 R >>',
            '<< /Type /Font /Subtype /CIDFontType2 /BaseFont /ABCDEF+Arial ' \
            '/CIDSystemInfo << /Registry (Adobe) /Ordering (Identity) ' \
            '/Supplement 0 >> /FontDescriptor 9 0 R /DW 500 >>',
            stream(cmap),
            '<< /Type /FontDescriptor /FontName /ABCDEF+Arial /Flags 32 ' \
            '/FontBBox [0 -200 1000 900] /ItalicAngle 0 /Ascent 900 ' \
            '/Descent -200 /CapHeight 700 /StemV 80 >>'
          ]
        )

        expect(&scan_after_masking(pdf, [decoded])).
          to raise_error(described_class::Error,
                         /still matches in the text pdftotext reads/)
      end

      {
        'spaced out' => 'J a n e  D o e l i t t l e',
        'hyphenated' => 'Jane Doe-little'
      }.each do |how, shown|
        it "finds the name #{how}, as a reader reads it" do
          pdf = page_pdf("BT /F1 12 Tf 72 700 Td (#{shown} attended.) Tj ET")

          expect(&scan_after_masking(pdf, [rule(secret)])).
            to raise_error(described_class::Error,
                           /still matches in the text pdftotext reads/)
        end
      end

      def utf16_attachment_pdf
        write(
          ['<< /Type /Catalog /Pages 2 0 R /Names << /EmbeddedFiles ' \
           '<< /Names [(a.txt) << /Type /Filespec /F (a.txt) ' \
           '/EF << /F 5 0 R >> >>] >> >> >>',
           '<< /Type /Pages /Kids [3 0 R] /Count 1 >>',
           '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 595 842] ' \
           '/Resources << /Font << /F1 6 0 R >> >> /Contents 4 0 R >>',
           stream(marked_secret),
           flate_stream('/Type /EmbeddedFile', utf16_secret), helvetica],
          root: 1, info: nil
        )
      end

      def utf16_secret
        "\xFE\xFF".b + "Minutes: #{secret} attended.".encode('UTF-16BE').b
      end

      # Best effort for the requester; but published as it is, the attached
      # file would carry the name, so the final scan still finds it.
      it 'serves a file with the name in an attached file left as it came, ' \
         'which the final scan still finds' do
        masked, report = described_class.redact(utf16_attachment_pdf,
                                                [rule(secret)])

        expect(text_of(masked)).not_to include(secret)
        expect(qdf_of(masked)).to include(utf16_secret)
        expect(report['unmasked_parts']).to match(
          [/\Aattached file \(object \d+\) is not a PDF or UTF-8 text\z/]
        )
        expect { described_class::FinalScan.check!(masked, [rule(secret)]) }.
          to raise_error(described_class::Error, /still matches in object/)
      end

      it 'fails if pdftotext is missing' do
        tools = PDFRedactor::LocalTools
        allow(tools).to receive(:program_path).and_call_original
        allow(tools).to receive(:program_path).
          with('pdftotext').
          and_raise(tools::ToolFailed, 'pdftotext is not installed')
        pdf = page_pdf('BT /F1 12 Tf 72 700 Td (Other words) Tj ET')

        expect(&scan_after_masking(pdf, [rule(secret)])).
          to raise_error(tools::ToolFailed, /pdftotext is not installed/)
      end

      # A file with one attached file, data, as object 4.
      def attaching(data, dict: '/Type /EmbeddedFile', spec: '')
        bare_page_pdf(
          catalog: '/Names << /EmbeddedFiles << /Names [(a) << /Type ' \
                   "/Filespec /F (a) /EF << /F 4 0 R >> #{spec} >>] >> >>",
          extra: ["<< #{dict} /Length #{data.bytesize} >>\nstream\n".b +
                  data + "\nendstream".b]
        )
      end

      def secret_page = page_pdf("BT /F1 12 Tf 72 700 Td (#{secret}) Tj ET")

      {
        'that is not PDF or text' => "PK\x03\x04\x00\x00Jane Doelittle".b,
        'in UTF-16' => "\xFF\xFE".b + 'Jane Doelittle'.encode('UTF-16LE').b
      }.each do |kind, data|
        it "serves a file with an attached file #{kind} as it came, and " \
           'says so' do
          masked, report = described_class.redact(attaching(data),
                                                  [rule(secret)])

          expect(qdf_of(masked)).to include(data)
          expect(report['unmasked_parts']).to match(
            [/\Aattached file \(object \d+\) is not a PDF or UTF-8 text\z/]
          )
        end
      end

      it 'serves a file with attached PDFs nested more than 3 deep, the ' \
         'deepest as it came, and says so' do
        pdf = 4.times.inject(secret_page) { |inner, _| attaching(inner) }

        _, report = described_class.redact(pdf, [rule(secret)])

        part, *others = report['unmasked_parts']
        expect(others).to be_empty
        expect(part.scan(/in attached PDF \(object \d+\): /).size).to eq(3)
        expect(part).to end_with('is nested more than 3 deep')
      end

      it 'serves a file with an attached PDF that has bytes before %PDF as ' \
         'it came, and says so' do
        data = "junk\n".b + secret_page

        masked, report = described_class.redact(attaching(data), [rule(secret)])

        expect(qdf_of(masked)).to include(data)
        expect(report['unmasked_parts']).to match(
          [/\Aattached file \(object \d+\) has bytes before %PDF\z/]
        )
      end

      it 'censors related files (/RF) as it does attached files' do
        pdf = bare_page_pdf(
          catalog: '/Names << /EmbeddedFiles << /Names [(a) << /Type ' \
                   '/Filespec /F (a) /EF << /F 4 0 R >> ' \
                   '/RF << /F [(b) 5 0 R] >> >>] >> >>',
          extra: [stream('Other text'), stream("Minutes: #{secret}")]
        )
        expect(leaks?(pdf, secret)).to be(true)

        masked, report = described_class.redact(pdf, [rule(secret)])

        expect(report['attached_text_censored']).to eq(1)
        expect(leaks?(masked, secret)).to be(false)
      end

      def final_scan(pdf) = described_class::FinalScan.check!(pdf, [rule(secret)])

      it 'finds the name in an attached PDF' do
        expect { final_scan(attaching(secret_page)) }.
          to raise_error(described_class::Error,
                         /still matches in the text pdftotext reads/)
      end

      it 'refuses a pure-ASCII attached PDF with leading whitespace' do
        data = "   \n".b + secret_page
        expect { final_scan(attaching(data)) }.
          to raise_error(described_class::Error, /can't be read/)
      end

      it 'refuses a non-attached stream holding a PDF with leading bytes' do
        pdf = bare_page_pdf(
          catalog: '/Extra 4 0 R',
          extra: [stream("   \n".b + secret_page)]
        )
        expect { final_scan(pdf) }.
          to raise_error(described_class::Error, /holds a PDF/)

        commented = bare_page_pdf(
          catalog: '/Extra 4 0 R',
          extra: [stream("   \n%PDF-1.4\n1%c\n0%c\nobj<<>>endobj")]
        )
        expect { final_scan(commented) }.
          to raise_error(described_class::Error, /holds a PDF/)
      end

      it 'scans plain text mentioning a PDF header as text' do
        clean = "The file starts with %PDF-1.7 and ends with %%EOF.\n"
        expect { final_scan(attaching(clean)) }.not_to raise_error

        text_stream = bare_page_pdf(
          catalog: '/Extra 4 0 R',
          extra: [stream(clean)]
        )
        expect { final_scan(text_stream) }.not_to raise_error

        dirty = "The file starts with %PDF-1.7: #{secret}.\n"
        expect { final_scan(attaching(dirty)) }.
          to raise_error(described_class::Matched)

        dirty_stream = bare_page_pdf(
          catalog: '/Extra 4 0 R',
          extra: [stream(dirty)]
        )
        expect { final_scan(dirty_stream) }.
          to raise_error(described_class::Matched)
      end

      {
        'a zip' => "PK\x03\x04\x00\x00notes".b,
        'PDFs nested more than 3 deep' => :nested
      }.each do |what, data|
        it "can’t read #{what} attached, so raises" do
          pdf = if data == :nested
                  4.times.inject(page_pdf('BT ET')) do |inner, _|
                    attaching(inner)
                  end
                else
                  attaching(data)
                end

          expect { final_scan(pdf) }.
            to raise_error(described_class::Error, /can't be read/)
        end
      end

      it 'can’t read an attached PDF that needs a password, so raises' do
        locked = encrypted_pdf(page_pdf('BT /F1 12 Tf 72 700 Td (Other) Tj ET'))

        expect { final_scan(attaching(locked)) }.
          to raise_error(described_class::PasswordRequired)
      end

      # LibreOffice's hybrid PDF attaches the whole source document, an ODF
      # zip, as /Type /EmbeddedFile in /EmbeddedFiles, with the trailer's
      # /AdditionalStreams pointing to it too.
      it 'serves a LibreOffice hybrid PDF with its source as it came, and ' \
         'says so' do
        unless system('which', 'soffice', out: File::NULL, err: File::NULL)
          skip 'LibreOffice missing'
        end

        pdf = Dir.mktmpdir do |dir|
          File.write("#{dir}/note.txt", "Minutes: #{secret} attended.\n")
          soffice = ['soffice', "-env:UserInstallation=file://#{dir}/profile",
                     '--headless', '--convert-to']
          quiet = { exception: true, out: File::NULL, err: File::NULL }
          hybrid = 'pdf:writer_pdf_Export:{"IsAddStream":' \
                   '{"type":"boolean","value":"true"}}'
          # --outdir must follow --convert-to.
          system(*soffice, 'odt', '--outdir', dir, "#{dir}/note.txt", **quiet)
          system(*soffice, hybrid, '--outdir', dir, "#{dir}/note.odt", **quiet)
          File.binread("#{dir}/note.pdf")
        end
        expect(pdf).to include('/AdditionalStreams', 'opendocument')

        masked, report = described_class.redact(pdf, [rule(secret)])

        expect(text_of(masked)).not_to include(secret)
        expect(report['unmasked_parts']).to match(
          [/\Aattached file \(object \d+\) is not a PDF or UTF-8 text\z/]
        )
      end

      it 'raises for a labelled page that already has a font named RIRedacted' do
        pdf = write(
          ['<< /Type /Catalog /Pages 2 0 R >>',
           '<< /Type /Pages /Kids [3 0 R] /Count 1 >>',
           '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 595 842] ' \
           '/Resources << /Font << /F1 4 0 R /RIRedacted 4 0 R >> >> ' \
           '/Contents 5 0 R >>',
           helvetica,
           stream("BT /F1 12 Tf 72 700 Td (#{secret} attended.) Tj ET")],
          root: 1, info: nil
        )

        expect { described_class.redact(pdf, [rule(secret)]) }.
          to raise_error(described_class::Error, /font named RIRedacted/)
      end

      it 'labels again a page an earlier pass labelled, in the same font' do
        pdf = write(
          ['<< /Type /Catalog /Pages 2 0 R >>',
           '<< /Type /Pages /Kids [3 0 R] /Count 1 >>',
           '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 595 842] ' \
           '/Resources << /Font << /F1 4 0 R >> >> /Contents 5 0 R >>',
           helvetica,
           stream("BT /F1 12 Tf 72 700 Td (#{secret} attended.) Tj ET " \
                  'BT /F1 12 Tf 72 680 Td (Rowan Requester asked.) Tj ET')],
          root: 1, info: nil
        )

        once, = described_class.redact(pdf, [rule(secret)])
        twice, = described_class.redact(once, [rule('Rowan Requester')])

        expect(text_of(twice)).not_to include(secret)
        expect(text_of(twice)).not_to include('Rowan Requester')
        expect(text_of(twice)).to include('attended.', 'asked.')
      end

      it 'censors an attached file that has no /Type' do
        pdf = attachment_pdf('')
        expect(leaks?(pdf, secret)).to be(true)

        masked, report = described_class.redact(pdf, [rule(secret)])

        expect(report['attached_text_censored']).to eq(1)
        expect(leaks?(masked, secret)).to be(false)
      end

      it 'leaves an attached file that is not PDF or text as it came, and ' \
         'says so' do
        odd = "PK\x03\x04\x00\x00#{secret}".b
        pdf = write(
          ['<< /Type /Catalog /Pages 2 0 R /Names << /EmbeddedFiles ' \
           '<< /Names [(a.zip) << /Type /Filespec /F (a.zip) ' \
           '/EF << /F 5 0 R >> >>] >> >> >>',
           '<< /Type /Pages /Kids [3 0 R] /Count 1 >>',
           '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 595 842] ' \
           '/Resources << /Font << /F1 6 0 R >> >> /Contents 4 0 R >>',
           stream(marked_secret), flate_stream('/Type /EmbeddedFile', odd),
           helvetica],
          root: 1, info: nil
        )

        masked, report = described_class.redact(pdf, [rule(secret)])

        expect(qdf_of(masked)).to include(odd)
        expect(text_of(masked)).not_to include(secret)
        expect(report['unmasked_parts']).to match(
          [/\Aattached file \(object \d+\) is not a PDF or UTF-8 text\z/]
        )
      end
    end

    context 'with a /Redact annotation' do
      let(:redact) do
        '<< /Type /Annot /Subtype /Redact /Rect [40 600 540 767] >>'
      end

      it 'raises for a file whose mark is a stream' do
        mark = '<< /Type /Annot /Subtype /Redact /Rect [40 600 540 767] ' \
               "/Length 3 >>\nstream\nq Q\nendstream"
        pdf = pages_pdf(
          ['/Resources << /Font << /F1 4 0 R >> >> /Contents 5 0 R ' \
           '/Annots [6 0 R]'],
          [helvetica, stream('BT /F1 12 Tf 72 700 Td (Other words) Tj ET'),
           mark]
        )

        expect { described_class.redact(pdf, [rule('Jane Doelittle')]) }.
          to raise_error(described_class::Error, /is a stream/)
      end

      it 'removes a mark with a censored string in it' do
        # The string's edit falls inside the mark, which is written as null.
        mark = '<< /Type /Annot /Subtype /Redact /Rect [40 600 540 767] ' \
               '/T (Jane Doelittle) >>'
        pdf = pages_pdf(
          ['/Resources << /Font << /F1 4 0 R >> >> /Contents 5 0 R ' \
           '/Annots [6 0 R]'],
          [helvetica, stream('BT /F1 12 Tf 72 700 Td (Other words) Tj ET'),
           mark]
        )

        masked, report = described_class.redact(pdf, [rule('Jane Doelittle')])

        expect(report['text_strings_censored']).to eq(1)
        expect(qdf_of(masked)).not_to include('/Redact')
        expect(qdf_of(masked)).not_to include('Doelittle')
      end

      it 'destroys an image under the mark and removes the mark' do
        pdf = pages_pdf(
          ["#{scan_page(5, 4)} /Annots [6 0 R]"],
          [stream(scan_content), image_object('Jane Doelittle'), redact]
        )

        masked, report = described_class.redact(pdf, [rule('Someone Else')])

        expect(report['pages_rasterized']).to eq(1)
        expect(qdf_of(masked)).not_to include('/Redact')
        expect(qdf_of(masked)).not_to include('/Width 1250')
        expect(ocr_text(masked)).not_to include('Doelittle')
      end

      it 'leaves nothing of the page for other objects to reach' do
        pdf = write(
          ['<< /Type /Catalog /Pages 2 0 R /Outlines 7 0 R ' \
           '/StructTreeRoot 9 0 R /Dests << /here [3 0 R /Fit] >> ' \
           '/AcroForm << /Fields [11 0 R] >> >>',
           '<< /Type /Pages /Kids [3 0 R] /Count 1 >>',
           "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 595 842] " \
           "#{scan_page(5, 4)} /Annots [6 0 R 11 0 R] >>",
           stream(scan_content), image_object('Jane Doelittle'), redact,
           '<< /Type /Outlines /First 8 0 R /Last 8 0 R /Count 1 >>',
           '<< /Title (Start) /Parent 7 0 R /Dest [3 0 R /Fit] >>',
           '<< /Type /StructTreeRoot /K 10 0 R >>',
           '<< /Type /StructElem /S /Figure /P 9 0 R /Pg 3 0 R ' \
           '/K << /Type /OBJR /Obj 6 0 R /Pg 3 0 R >> >>',
           '<< /Type /Annot /Subtype /Widget /FT /Tx /T (a) /P 3 0 R ' \
           '/Rect [0 0 9 9] >>'],
          root: 1, info: nil
        )

        masked, = described_class.redact(pdf, [rule('Someone Else')])

        expect(qdf_of(masked)).not_to include('/Width 1250')
        expect(qdf_of(masked)).not_to include('/Redact')
      end

      it 'destroys text in a form under the mark' do
        pdf = pages_pdf(
          ['/Resources << /XObject << /Fm0 5 0 R >> >> /Contents 4 0 R ' \
           '/Annots [6 0 R]'],
          [stream('/Fm0 Do'), name_form(7), redact, helvetica]
        )

        masked, = described_class.redact(pdf, [rule('Someone Else')])

        expect(text_of(masked)).not_to include('Doelittle')
        expect(qdf_of(masked)).not_to include('Doelittle')
        expect(ocr_text(masked)).not_to include('Doelittle')
      end

      it 'leaves no annotation drawn over the mark' do
        stamp = "<< /Type /Annot /Subtype /Stamp /Rect [0 0 595 842] " \
                '/AP << /N 8 0 R >> >>'
        pdf = pages_pdf(
          ['/Resources << >> /Contents 4 0 R /Annots [5 0 R 6 0 R]'],
          [stream('q Q'), redact, stamp, helvetica,
           name_form(7, before: '1 g 0 0 595 842 re f 0 g ')]
        )

        masked, = described_class.redact(pdf, [rule('Someone Else')])

        expect(ocr_text(masked)).not_to include('Doelittle')
      end

      it 'keeps the pages without a mark as they were' do
        pdf = pages_pdf(
          ['/Resources << >> /Contents 5 0 R /Annots [7 0 R]',
           '/Resources << /Font << /F1 8 0 R >> >> /Contents 6 0 R'],
          [stream('q Q'), stream('BT /F1 12 Tf 72 700 Td (Kept words) Tj ET'),
           redact, helvetica]
        )

        masked, report = described_class.redact(pdf, [rule('Someone Else')])

        expect(report['pages_rasterized']).to eq(1)
        expect(text_of(masked)).to include('Kept words')
      end
    end

    context 'when pages share a content stream' do
      let(:content) { 'BT /F1 12 Tf 72 700 Td (Jane Doelittle) Tj ET' }

      # Without a raw-byte pass, which matches whatever the fonts draw.
      let(:decoded_rule) do
        described_class::Rule.new(
          described_class.tolerant('Jane Doelittle', false), true, nil,
          'Jane Doelittle'
        )
      end

      def pages_with_fonts(first, second)
        pages_pdf(
          ['/Resources << /Font << /F1 6 0 R >> >> /Contents 5 0 R',
           '/Resources << /Font << /F1 7 0 R >> >> /Contents 5 0 R'],
          [stream(content), first, second]
        )
      end

      def text_of_page(pdf, number)
        Tempfile.create(['redacted', '.pdf']) do |file|
          file.binmode
          file.write(pdf)
          file.flush
          `pdftotext -f #{number} -l #{number} #{file.path} -`.
            gsub(/\s+/, ' ').strip
        end
      end

      it 'checks a later page by its own fonts' do
        pdf = pages_with_fonts(zed_font, helvetica)
        expect(text_of_page(pdf, 2)).to include('Jane Doelittle')

        masked, report = described_class.redact(pdf, [decoded_rule])

        expect(report['matches']).to eq(1)
        expect(text_of_page(masked, 2)).not_to include('Doelittle')
        expect(text_of_page(masked, 1)).to eq(text_of_page(pdf, 1))
      end

      it 'does not change a later page for a match on the first' do
        pdf = pages_with_fonts(helvetica, zed_font)

        masked, = described_class.redact(pdf, [decoded_rule])

        expect(text_of_page(masked, 1)).not_to include('Doelittle')
        expect(text_of_page(masked, 2)).to eq(text_of_page(pdf, 2))
      end

      it 'reads each scanned page by its own image' do
        skip 'OCR tools missing' unless ocr_tools?

        pdf = pages_pdf(
          [scan_page(6, 5), scan_page(7, 5)],
          [stream(scan_content), image_object('Nothing here'),
           image_object('Jane Doelittle')]
        )

        masked, report = described_class.redact(pdf, [rule('Jane Doelittle')],
                                                ocr: true)

        expect(report['ocr_pages']).to eq(2)
        expect(report['pages_rasterized']).to eq(1)
        pages = ocr_pages(masked)
        expect(pages[0]).to include('Nothing')
        expect(pages[1]).not_to include('Doelittle')
      end

      it 'reads a scanned page that appears twice' do
        skip 'OCR tools missing' unless ocr_tools?

        pdf = pages_pdf(
          [scan_page(6, 5), scan_page(6, 5)],
          [stream(scan_content), image_object('Jane Doelittle')]
        )

        masked, report = described_class.redact(pdf, [rule('Jane Doelittle')],
                                                ocr: true)

        expect(report['pages_rasterized']).to eq(2)
        expect(ocr_pages(masked).join).not_to include('Doelittle')
      end
    end

    context 'when pages share a form' do
      it 'reads a scan in a form on each page that draws it' do
        skip 'OCR tools missing' unless ocr_tools?

        body = scan_content
        form = "<< /Type /XObject /Subtype /Form /BBox [0 0 595 842] " \
               "/Resources << /XObject << /Im0 8 0 R >> >> " \
               "/Length #{body.bytesize} >>\nstream\n#{body}\nendstream"
        page = '/Resources << /XObject << /Fm0 7 0 R >> >> /Contents %d 0 R'
        pdf = pages_pdf(
          [page % 5, page % 6],
          [stream('/Fm0 Do'), stream('/Fm0 Do'), form,
           image_object('Jane Doelittle')]
        )

        masked, report = described_class.redact(pdf, [rule('Jane Doelittle')],
                                                ocr: true)

        expect(report['pages_rasterized']).to eq(2)
        expect(ocr_pages(masked).join).not_to include('Doelittle')
      end

      it 'fails when the form reads differently on each page' do
        body = 'BT /F1 12 Tf 72 700 Td (Jane Doelittle) Tj ET'
        form = "<< /Type /XObject /Subtype /Form /BBox [0 0 595 842] " \
               "/Length #{body.bytesize} >>\nstream\n#{body}\nendstream"
        page = '/Resources << /XObject << /Fm0 7 0 R >> /Font << /F1 %d 0 R ' \
               '>> >> /Contents 5 0 R'
        pdf = pages_pdf(
          [page % 8, page % 9],
          [stream('/Fm0 Do'), stream('q Q'), form, zed_font, helvetica]
        )

        expect { described_class.redact(pdf, [rule('Jane Doelittle')]) }.
          to raise_error(described_class::Error, /form/)
      end
    end

    context 'when OCR is asked for' do
      it 'checks tool availability again when the backend changes' do
        original = described_class.backend
        missing_tools = original.dup
        allow(missing_tools).to receive(:program_path).
          and_raise(missing_tools::ToolError)
        allow(original).to receive(:program_path) { |name| "/usr/bin/#{name}" }

        described_class.backend = missing_tools
        expect(described_class::Ocr.available?).to be(false)
        described_class.backend = original
        expect(described_class::Ocr.available?).to be(true)
      ensure
        described_class.backend = original
      end

      it 'fails when a scanned page cannot be read' do
        skip 'OCR tools missing' unless ocr_tools?

        allow(described_class::Ocr).to receive(:read_pages).and_return([nil])

        expect do
          described_class.redact(scanned_pdf('Jane Doelittle'),
                                 [rule('Jane Doelittle')], ocr: true)
        end.to raise_error(described_class::Error, /OCR could not read page 1/)
      end

      it 'fails when a scanned page cannot be read as OCR is not installed' do
        scan = scanned_pdf('Jane Doelittle')
        allow(described_class::Ocr).to receive(:available?).and_return(false)

        expect do
          described_class.redact(scan, [rule('Jane Doelittle')], ocr: true)
        end.to raise_error(described_class::Error, /OCR is not available/)
      end

      it 'does not need OCR for a page with text' do
        allow(described_class::Ocr).to receive(:available?).and_return(false)
        pdf = page_pdf('BT /F1 12 Tf 72 700 Td (Jane Doelittle) Tj ET')

        masked, = described_class.redact(pdf, [rule('Jane Doelittle')],
                                         ocr: true)

        expect(text_of(masked)).not_to include('Doelittle')
      end

      it 'reads the scanned pages of an attached PDF' do
        skip 'OCR tools missing' unless ocr_tools?

        scan = scanned_pdf('Minutes: Jane Doelittle attended.')
        attached = "<< /Type /EmbeddedFile /Length #{scan.bytesize} >>\n" \
                   "stream\n#{scan}\nendstream"
        pdf = write(
          ['<< /Type /Catalog /Pages 2 0 R /Names << /EmbeddedFiles ' \
           '<< /Names [(a.pdf) << /Type /Filespec /F (a.pdf) ' \
           '/EF << /F 5 0 R >> >>] >> >> >>',
           '<< /Type /Pages /Kids [3 0 R] /Count 1 >>',
           '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 595 842] ' \
           '/Resources << >> /Contents 4 0 R >>',
           stream('q Q'), attached],
          root: 1, info: nil
        )
        expect(described_class::Ocr).to receive(:read_pages).
          at_least(:once).and_call_original

        masked, = described_class.redact(pdf, [rule('Jane Doelittle')],
                                         ocr: true)

        Tempfile.create(['redacted', '.pdf']) do |file|
          file.binmode
          file.write(masked)
          file.flush
          out = IO.popen(['qpdf', '--show-attachment=a.pdf', file.path], &:read)
          expect(ocr_text(out)).not_to include('Doelittle')
        end
      end
    end
  end

  describe '.tolerant' do
    let(:pattern) { described_class.tolerant('Jane Doelittle', false) }

    it 'matches across layout gaps, line breaks and end-of-line hyphens' do
      expect("Jane#{described_class::LINE}Doelittle").to match(pattern)
      expect("Jane Doe-#{described_class::LINE}little").to match(pattern)
      expect("J#{described_class::GAP}ane Doelittle").to match(pattern)
    end

    it 'keeps to the case of the rule unless told otherwise' do
      expect('jane doelittle').not_to match(pattern)
      expect('jane doelittle').
        to match(described_class.tolerant('Jane Doelittle', true))
    end
  end
end
