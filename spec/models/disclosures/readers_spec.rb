require 'spec_helper'
require 'tmpdir'
require 'zip'

RSpec.describe 'Disclosures readers' do
  def in_file(bytes, name)
    Dir.mktmpdir('disclosures-spec') do |dir|
      path = File.join(dir, name)
      File.binwrite(path, bytes)
      yield path, dir
    end
  end

  let(:born) { (Date.new(1984, 3, 9) - Date.new(1899, 12, 30)).to_i }
  let(:formatted) do
    DocumentFixtures.styled_xlsx(
      [[born, 1], [3.14159, 2], [1_234_567, 3], [0.125, 4],
       [-1234.5, 5], [1_234_567.891, 6], [2.25, 7], [12_345, 8],
       [born + 0.75, 9], ['Plain text', 0], [5200, 0]],
      formats: ['yyyy', '#,##0,"k"', '"£"#,##0.00;[Red]-"£"#,##0.00',
                '0.0', 'd mmmm yyyy h:mm AM/PM'],
      xfs: [[0, 0], [164, 0], [2, 0], [165, 0], [9, 0],
            [166, 0], [4, 0], [167, 0], [11, 0], [168, 0]]
    )
  end

  describe Disclosures::Sheets do
    let(:workbook) do
      DocumentFixtures.xlsx(
        sheets: [{ name: 'Summary',
                   rows: [%w[Ward Repairs Officer Cost],
                          ['North', 12, 'HIDDENCOLUMN Jane', 5200],
                          ['HIDDENROW Jane Example', 1, 'x', 1],
                          ['South', 9, 'HIDDENCOLUMN John', 3100]],
                   hidden_rows: [3],
                   hidden_columns: ['C'] },
                 { name: 'Staff',
                   hidden: true,
                   rows: [%w[Name], ['HIDDENSHEET Jane Example']] },
                 { name: 'Lookups',
                   hidden: :very,
                   rows: [%w[Code], ['VERYHIDDEN 42']] }]
      )
    end

    it 'reads only visible sheets, rows and columns, through shared strings' do
      in_file(workbook, 'repairs.xlsx') do |path|
        sheets = described_class.read_xlsx(path)
        expect(sheets.map(&:name)).to eq(['Summary'])
        expect(sheets.first.rows).
          to eq([%w[Ward Repairs Cost], %w[North 12 5200], %w[South 9 3100]])
        expect(sheets.first.text).not_to include('HIDDEN', 'VERYHIDDEN')
      end
      expect(workbook).to include('xl/sharedStrings.xml')
    end

    def dated_workbook
      main = 'application/vnd.openxmlformats-officedocument.spreadsheetml'
      ns = DocumentFixtures::SPREADSHEET_NS
      columns = %w[A B C D]
      cells = [[0, '45658'], [1, '45658'], [2, '45658'], [3, '45658.5']].
        each_with_index.map do |(style, value), index|
          %(<c r="#{columns[index]}1" s="#{style}"><v>#{value}</v></c>)
        end.join
      AttachmentFixtures.ooxml(
        '[Content_Types].xml' => AttachmentFixtures.content_types(
          '/xl/workbook.xml' => "#{main}.sheet.main+xml",
          '/xl/worksheets/sheet1.xml' => "#{main}.worksheet+xml",
          '/xl/styles.xml' => "#{main}.styles+xml"
        ),
        '_rels/.rels' => AttachmentFixtures.rels(
          'officeDocument' => 'xl/workbook.xml'
        ),
        'xl/workbook.xml' => %(<workbook #{ns}><sheets>) \
                             '<sheet name="Dates" sheetId="1" r:id="rId1"/>' \
                             '</sheets></workbook>',
        'xl/_rels/workbook.xml.rels' => AttachmentFixtures.rels(
          'worksheet' => 'worksheets/sheet1.xml', 'styles' => 'styles.xml'
        ),
        'xl/styles.xml' => %(<styleSheet #{ns}><numFmts count="1">) \
                           '<numFmt numFmtId="164" formatCode="dd/mm/yyyy"/>' \
                           '</numFmts>' \
                           '<cellXfs count="4"><xf numFmtId="0"/>' \
                           '<xf numFmtId="14"/><xf numFmtId="164"/>' \
                           '<xf numFmtId="22"/></cellXfs></styleSheet>',
        'xl/worksheets/sheet1.xml' => %(<worksheet #{ns}><sheetData>) \
                                      '<row r="1">' \
                                      "#{cells}</row></sheetData></worksheet>"
      )
    end

    it 'shows numbers with a date format, built in or custom, as dates' do
      in_file(dated_workbook, 'dates.xlsx') do |path|
        expect(described_class.read_xlsx(path).first.rows).
          to eq([['45658', '2025-01-01', '01/01/2025', '2025-01-01 12:00']])
      end
    end

    it 'shows each number as its format does: years, decimals, thousands, percentages and currency' do
      in_file(formatted, 'formatted.xlsx') do |path|
        sheet = described_class.read_xlsx(path).first
        expect(sheet.rows).to eq(
          [['1984', '3.14', '1,235k', '13%', '-£1,234.50', '1,234,567.89',
            '2.3', '1.23E+04', '9 March 1984 6:00 PM', 'Plain text', '5200']]
        )
        expect(sheet).to have_attributes(hidden_cells: 0, unformatted_cells: 0)
      end
    end

    it 'leaves out cells hidden by a ;;; format or by white text, and counts them' do
      book = DocumentFixtures.styled_xlsx([['Visible', 0],
                                           ['Jane Hidden', 1], [4242, 1],
                                           ['Whitetext Name', 2], [9, 0]],
                                          formats: [';;;'],
                                          xfs: [[0, 0], [164, 0], [0, 1]])
      in_file(book, 'hidden.xlsx') do |path|
        sheet = described_class.read_xlsx(path).first
        expect(sheet.rows).to eq([['Visible', '', '', '', '9']])
        expect(sheet.hidden_cells).to eq(3)
        expect(sheet.text).not_to include('Jane', '4242', 'Whitetext')
      end
    end

    it 'gives a value in a format it can’t follow as stored, and counts it' do
      book = DocumentFixtures.styled_xlsx([[1.5, 1], [7, 0]],
                                          formats: [],
                                          xfs: [[0, 0], [12, 0]])
      in_file(book, 'fractions.xlsx') do |path|
        sheet = described_class.read_xlsx(path).first
        expect(sheet.rows).to eq([%w[1.5 7]])
        expect(sheet.unformatted_cells).to eq(1)
      end
    end

    it 'caps the cells read across the whole workbook when whole sheets are wanted' do
      stub_const('Disclosures::Sheets::MAX_CELLS', 5)
      book = DocumentFixtures.xlsx(sheets: [{ name: 'One', rows: [%w[a b c]] },
                                            { name: 'Two', rows: [%w[d e f]] }])
      in_file(book, 'two.xlsx') do |path|
        expect(described_class.read_xlsx(path).size).to eq(2)
        expect {
          described_class.read_xlsx(path, max_rows: nil, max_columns: nil)
        }.to raise_error(Disclosures::Error::Refused, /too large/)
      end
    end

    it 'reads a Windows-1252 CSV and drops a UTF-8 byte-order mark' do
      windows = described_class.read_csv("Name,Note\nCaf\xE9,\x80 5\n".b)
      expect(windows.rows).to eq([%w[Name Note], ['Café', '€ 5']])

      bom = described_class.read_csv("\xEF\xBB\xBFName,Count\nNorth,3\n".b)
      expect(bom.rows.first).to eq(%w[Name Count])
      expect(bom.text).not_to include("﻿")
    end
  end

  describe Disclosures::PDFText do
    def page_text(pages)
      in_file(AttachmentFixtures.pdf(pages: pages), 'input.pdf') do |path, dir|
        described_class.pages(path, pages.size, dir, job: nil)
      end
    end

    it 'leaves out words under a filled box, white words and words outside the crop box, and counts them' do
      page = page_text(
        [{ crop_box: [0, 300, 595, 842],
           texts: [
             { x: 72, y: 760, text: 'Visible heading about repairs', size: 14 },
             { x: 72, y: 700, text: 'Covered Coveredname Example', size: 12 },
             { x: 72,
               y: 650,
               text: 'Whiteword invisible',
               size: 12,
               colour: [1, 1, 1] },
             { x: 72, y: 100, text: 'Outsidecrop footer', size: 12 }
           ],
           boxes: [{ x: 66, y: 694, w: 330, h: 22 }] }]
      ).first
      expect(page.text).to include('Visible heading about repairs')
      expect(page.text).
        not_to include('Coveredname', 'Whiteword', 'Outsidecrop')
      expect(page.hidden).to eq(7)
    end

    it 'counts nothing on a page where every word shows' do
      page = page_text(
        [{ texts: [{ x: 72, y: 760, text: 'Nothing hidden here', size: 14 }] }]
      ).first
      expect(page.text).to eq('Nothing hidden here')
      expect(page.hidden).to eq(0)
    end

    def raw_pdf(*operators, rotate: nil)
      content = operators.join("\n")
      AttachmentFixtures.write(
        ['<< /Type /Catalog /Pages 2 0 R >>',
         '<< /Type /Pages /Kids [5 0 R] /Count 1 >>',
         '<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>',
         "<< /Length #{content.bytesize} >>\nstream\n#{content}\nendstream",
         "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 595 842]" \
         "#{" /Rotate #{rotate}" if rotate} " \
         '/Resources << /Font << /F1 3 0 R >> >> /Contents 4 0 R >>'],
        root: 1,
        info: nil
      )
    end

    def words(text, x, y, size, colour: '0 0 0')
      "BT #{colour} rg /F1 #{size} Tf #{x} #{y} Td (#{text}) Tj ET"
    end

    def box(x0, y0, x1, y1)
      "0 0 0 rg #{x0} #{y0} #{x1 - x0} #{y1 - y0} re f"
    end

    def pages_of(pdf)
      in_file(pdf, 'input.pdf') do |path, dir|
        described_class.pages(path, 1, dir, job: nil)
      end
    end

    it 'counts words under a box drawn flush with their edges as hidden' do
      text = [words('Visible heading about repairs', 72, 760, 14),
              words('Jane Smith', 72, 700, 12)]
      found = in_file(raw_pdf(*text), 'plain.pdf') do |path, _dir|
        described_class.bbox_layout(path, 1, job: nil).xpath('//word').
          map { |node| described_class.word_of(node) }
      end
      name_words = %w[Jane Smith]
      name = found.select { |word| name_words.include?(word[:text]) }
      # Word's black highlighting: the words' own box (PDF y runs up).
      flush = box(name.map { |word| word[:x0] }.min,
                  842 - name.map { |word| word[:y1] }.max,
                  name.map { |word| word[:x1] }.max,
                  842 - name.map { |word| word[:y0] }.min)

      page = pages_of(raw_pdf(*text, flush)).first
      expect(page.text).to eq('Visible heading about repairs')
      expect(page.hidden).to eq(2)
      expect(pages_of(raw_pdf(*text)).first).
        to have_attributes(text: "Visible heading about repairs\nJane Smith",
                           hidden: 0)
    end

    it 'counts words under a redaction box as hidden although a white label is written over them' do
      page = pages_of(
        raw_pdf(words('Visible heading about repairs', 72, 760, 14),
                words('Jane Smith Example', 72, 700, 12),
                box(66, 694, 200, 716),
                words('s.40(2)', 100, 701, 11, colour: '1 1 1'))
      ).first
      expect(page.text).to start_with('Visible heading about repairs')
      expect(page.text).not_to include('Jane', 'Smith', 'Example')
      expect(page.hidden).to be >= 3
    end

    [90, 270].each do |rotate|
      it "finds the visible and the boxed words on a page turned #{rotate} degrees" do
        page = page_text(
          [{ rotate: rotate,
             texts: [{ x: 72,
                       y: 760,
                       text: 'Visible heading about repairs',
                       size: 14 },
                     { x: 72, y: 600, text: 'Covered Coveredname', size: 16 }],
             boxes: [{ x: 66, y: 594, w: 330, h: 24 }] }]
        ).first
        expect(page.text.split).
          to match_array(%w[Visible heading about repairs])
        expect(page.hidden).to eq(2)
      end
    end

    it 'looks at a huge page at a lower resolution' do
      pdf = AttachmentFixtures.pdf(
        pages: [{ size: [14_400, 7_200],
                  texts: [{ x: 720, y: 3_600, text: 'Site plan', size: 600 }] }]
      )
      in_file(pdf, 'plan.pdf') do |path, dir|
        grey = described_class.render_grey(path, 1, dir, job: nil)
        expect([grey[:width], grey[:height]].max).
          to be <= AttachmentManagement::Engines::Raster::MAX_SIDE
        expect(described_class.pages(path, 1, dir, job: nil).first).
          to have_attributes(text: 'Site plan', hidden: 0)
      end
    end

    it 'keeps the columns of a table apart' do
      rows = [%w[Ward Repairs Cost], %w[North 12 5200], %w[South 9 3100]]
      texts = rows.each_with_index.flat_map do |row, r|
        row.each_with_index.map do |cell, c|
          { x: 72 + (c * 160), y: 700 - (r * 20), text: cell, size: 11 }
        end
      end
      lines = page_text([{ texts: texts }]).first.text.lines.map(&:chomp)
      expect(lines.size).to eq(3)
      expect(lines[0]).to match(/\AWard\s{3,}Repairs\s{3,}Cost\z/)
      expect(lines[1]).to match(/\ANorth\s{3,}12\s{3,}5200\z/)
    end
  end
end
