require 'spec_helper'
require 'tmpdir'
require 'zip'

RSpec.describe 'Disclosures security: files' do
  include ActiveJob::TestHelper
  include DisclosuresHelpers
  include_context 'with document OCR off'

  let(:owner) { FactoryBot.create(:user, name: 'Rowan Requester') }
  let(:admin) { FactoryBot.create(:admin_user) }
  let(:info_request) do
    FactoryBot.create(:info_request, user: owner, title: 'Fleet vehicles 2025')
  end
  let(:docx_type) { Disclosures::Formats::DOCUMENT['.docx'] }

  def ingest(name, type, bytes)
    delivered_document(info_request, name, type, bytes, by: owner, ready: false)
  end

  def make_document(name, type, bytes)
    delivered_document(info_request, name, type, bytes, by: owner)
  end

  def publication(document)
    Disclosures::Publication.new(document.reload, user: admin)
  end

  def in_file(bytes, name)
    Dir.mktmpdir('disclosures-spec') do |dir|
      path = File.join(dir, name)
      File.binwrite(path, bytes)
      yield path
    end
  end

  # Sets the uncompressed size that one part declares, in its local header and
  # in the central directory (updating Zip64 extra info when present).
  def declare(bytes, name, size)
    data = bytes.b
    {
      "PK\x03\x04".b => [26, 30, 22], "PK\x01\x02".b => [28, 46, 24]
    }.each do |signature, (length_at, name_at, size_at)|
      offset = 0
      while (offset = data.index(signature, offset))
        length, extra_length = data.unpack("@#{offset + length_at}vv")
        if data.byteslice(offset + name_at, length) == name.b
          if data.unpack1("@#{offset + size_at}V") == 0xFFFFFFFF
            patch_zip64_usize(data, offset + name_at + length,
                              extra_length, size)
          else
            data[offset + size_at, 4] = [size].pack('V')
          end
        end
        offset += 4
      end
    end
    data
  end

  def patch_zip64_usize(data, extra_start, extra_length, size)
    pos = extra_start
    limit = extra_start + extra_length
    while pos + 4 <= limit
      header, field_size = data.unpack("@#{pos}vv")
      if header == 0x0001 && field_size >= 8 && pos + 12 <= limit
        data[pos + 4, 8] = [size].pack('Q<')
        return
      end
      pos += 4 + field_size
    end
  end

  def pptx(count, presentation: nil)
    p_ns = 'xmlns:p="http://schemas.openxmlformats.org/' \
           'presentationml/2006/main" ' \
           'xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main"'
    files = { 'ppt/presentation.xml' => presentation ||
                                        %(<p:presentation #{p_ns}>) \
                                        '<p:sldSz cx="9144000" cy="6858000"/>' \
                                        '</p:presentation>' }
    (1..count).each do |number|
      x = number == 9 ? 9_500_000 : 500_000
      files["ppt/slides/slide#{number}.xml"] =
        %(<p:sld #{p_ns}#{' show="0"' if number == 7}><p:cSld><p:spTree>) \
        '<p:sp><p:spPr><a:xfrm>' +
        %(<a:off x="#{x}" y="500000"/>) \
        '<a:ext cx="2000000" cy="500000"/></a:xfrm></p:spPr>' +
        %(<p:txBody><a:p><a:r><a:t>Slide #{number}</a:t></a:r></a:p>) \
        '</p:txBody></p:sp></p:spTree></p:cSld></p:sld>'
    end
    DocumentFixtures.zip(files)
  end

  def refused(pattern)
    raise_error(Disclosures::ZipGuard::Refused,
                /too large or too complex to process here \(#{pattern}/)
  end

  describe 'HTML' do
    it 'tells the styles that can hide text from those that can’t' do
      hiding = [
        '<style>.x{font-size:0}</style><p class="x">a</p>',
        '<p style="opacity: 0">a</p>', '<p style="color:#FFFFFF">a</p>',
        '<link rel="Stylesheet" href="https://example.test/a.css"><p>a</p>',
        '<style>@import url(a.css);</style>',
        '<style>p{visibility: hidden}</style>',
        '<style>.o{position:absolute;left:-9999px}</style>',
        '<font color="white">a</font>'
      ]
      showing = [
        '<p style="display:none">removed with its element</p>',
        '<style>p{color:red;font-size:11.0pt}</style>',
        '<style>' \
        'p.MsoListParagraph{text-indent:-18.0pt;margin-left:36.0pt}</style>',
        '<style>span{text-transform:uppercase;line-height:0.5em}</style>',
        '<p>a</p>'
      ]
      hiding.each do |html|
        expect(Disclosures::Renderer.hiding_styles?(html)).to be(true), html
      end
      showing.each do |html|
        expect(Disclosures::Renderer.hiding_styles?(html)).to be(false), html
      end
    end
  end

  describe Disclosures::ZipGuard do
    let(:docx) do
      DocumentFixtures.docx(paragraphs: ['Fleet vehicles by depot.'])
    end

    def check(bytes, name = 'file.docx', unpack: false)
      in_file(bytes, name) do |path|
        described_class.check!(path, unpack: unpack)
      end
    end

    it 'passes an ordinary Office file' do
      expect(check(docx, unpack: true)).to be(true)
      expect(check(DocumentFixtures.xlsx(sheets: [{ name: 'Fleet',
                                                    rows: [%w[Depot Vans]] }]),
                   'fleet.xlsx')).to be(true)
    end

    it 'refuses more than 2,000 parts, before anything opens the archive' do
      files = Zip::File.open_buffer(StringIO.new(docx)).entries.
        to_h { |entry| [entry.name, entry.get_input_stream.read] }
      2_000.times { |index| files["customXml/item#{index}.xml"] = '<a/>' }
      many = DocumentFixtures.zip(files)
      expect(Zip::File).not_to receive(:new)
      expect { check(many) }.to refused('more than 2000 parts')
      expect { Disclosures::Formats.supported?(docx_type, 'many.docx', many) }.
        to refused('more than 2000 parts')
    end

    it 'refuses more than 200 MB unpacked, a part compressed more than 200 to 1, and an XML part over 20 MB' do
      large = DocumentFixtures.zip('word/document.xml' => '<w:document/>',
                                   'word/media/image1.png' => 'png')
      expect { check(declare(large, 'word/media/image1.png', 201.megabytes)) }.
        to refused('over 200 MB unpacked')
      expect {
        check(
          DocumentFixtures.zip('word/document.xml' => '<w:document/>',
                               'word/media/blank.bin' => "\0" * 2.megabytes)
        )
      }.to refused('a part compressed more than 200 to 1')
      expect { check(declare(large, 'word/document.xml', 21.megabytes)) }.
        to refused('a part over 20 MB')
    end

    it 'refuses more than 200 worksheets or 500 slides, by part or as listed' do
      expect {
        check(
          DocumentFixtures.xlsx(
            sheets: (1..201).map { |n| { name: "S#{n}", rows: [['a']] } }
          ),
          'many.xlsx'
        )
      }.to refused('more than 200 sheets')
      ns = DocumentFixtures::SPREADSHEET_NS
      listed = DocumentFixtures.zip(
        'xl/workbook.xml' =>
          %(<workbook #{ns}><sheets>) \
          "#{'<sheet name="S" sheetId="1" r:id="rId1"/>' * 201}" \
          '</sheets></workbook>',
        'xl/worksheets/sheet1.xml' => %(<worksheet #{ns}><sheetData/>) \
                                      '</worksheet>'
      )
      expect { check(listed, 'listed.xlsx') }.to refused('more than 200 sheets')

      expect { check(pptx(501), 'many.pptx') }.
        to refused('more than 500 slides')
      p_ns = 'xmlns:p="http://schemas.openxmlformats.org/' \
             'presentationml/2006/main"'
      ids = (1..501).map { |n| %(<p:sldId id="#{255 + n}"/>) }.join
      expect {
        check(pptx(1,
                   presentation: %(<p:presentation #{p_ns}>) \
                                 "<p:sldIdLst>#{ids}</p:sldIdLst>" \
                                 '</p:presentation>'),
              'listed.pptx')
      }.to refused('more than 500 slides')
    end

    it 'looks up main parts case-insensitively and rejects DOCTYPEs' do
      ns = DocumentFixtures::SPREADSHEET_NS
      upper = DocumentFixtures.zip(
        'XL/WORKBOOK.XML' =>
          %(<workbook #{ns}><sheets>) \
          "#{'<sheet name="S" sheetId="1" r:id="rId1"/>' * 201}" \
          '</sheets></workbook>',
        'xl/worksheets/sheet1.xml' => %(<worksheet #{ns}><sheetData/>) \
                                      '</worksheet>'
      )
      expect { check(upper, 'upper.xlsx') }.to refused('more than 200 sheets')

      dtd = '<!DOCTYPE x><workbook/>'
      [dtd, "\xFF\xFE".b + dtd.encode('UTF-16LE').b].each do |xml|
        with_dtd = DocumentFixtures.zip(
          'xl/workbook.xml' => xml,
          'xl/worksheets/sheet1.xml' => %(<worksheet #{ns}><sheetData/>) \
                                        '</worksheet>'
        )
        expect { check(with_dtd, 'dtd.xlsx') }.
          to refused('a part that declares a DOCTYPE')
      end
    end

    it 'refuses overlapping entries and multiple EOCD records when unpacking' do
      zip_entries = [['[Content_Types].xml', OfficeFixtures.content_types({})],
                     ['word/document.xml', '<doc/>']]
      once = OfficeFixtures.zip(zip_entries)
      overlapping = once.dup
      directory = overlapping.index("PK\x01\x02".b)
      csize = overlapping.unpack1("@#{directory + 20}V")
      overlapping[directory + 20, 4] = [csize + 10].pack('V')
      expect { check(overlapping, unpack: true) }.
        to refused('entries that overlap')

      record = once.byteslice(once.rindex("PK\x05\x06".b), 22)
      double_eocd = OfficeFixtures.zip(zip_entries, comment: record)
      expect { check(double_eocd, unpack: true) }.
        to refused('more than one end of central directory')
    end

    it 'refuses a part larger than the archive says, however it is read' do
      lying = declare(docx, 'word/document.xml', 100)
      expect(check(lying)).to be(true)
      expect { check(lying, unpack: true) }.
        to refused('a part larger than the archive says')
      in_file(lying, 'lying.docx') do |path|
        Zip::File.open(path) do |zip|
          expect { described_class.read(zip.find_entry('word/document.xml')) }.
            to refused('a part larger than the archive says')
        end
        expect(AttachmentManagement::OfficeInspector.findings(path)).
          to eq(['Too large or too complex to open here, so its hidden ' \
                 'content could not be listed.'])
      end
    end

    it 'is used by the readers and by the attachment tool’s inspector' do
      many_sheets = DocumentFixtures.xlsx(
        sheets: (1..201).map { |n| { name: "S#{n}", rows: [['a']] } }
      )
      in_file(many_sheets, 'many.xlsx') do |path|
        expect { Disclosures::Sheets.read_xlsx(path) }.
          to refused('more than 200 sheets')
        expect(AttachmentManagement::OfficeInspector.findings(path)).
          to eq(['Too large or too complex to open here, so its hidden ' \
                 'content could not be listed.'])
      end
      in_file('not a zip', 'n.docx') do |path|
        expect(AttachmentManagement::OfficeInspector.findings(path)).
          to eq(['Not an Office Open XML file, so its hidden content could ' \
                 'not be listed.'])
      end
    end

    it 'reads a presentation of many slides one at a time, with the same findings' do
      deck = pptx(300)
      expect(check(deck, 'deck.pptx', unpack: true)).to be(true)
      in_file(deck, 'deck.pptx') do |path|
        expect(AttachmentManagement::OfficeInspector.findings(path)).to eq([])
      end
    end
  end

  describe 'a hostile spreadsheet' do
    def sheet_xlsx(rows, cols: '')
      main = 'application/vnd.openxmlformats-officedocument.spreadsheetml'
      ns = 'xmlns="http://schemas.openxmlformats.org/' \
           'spreadsheetml/2006/main" ' \
           'xmlns:r="http://schemas.openxmlformats.org/' \
           'officeDocument/2006/relationships"'
      AttachmentFixtures.ooxml(
        '[Content_Types].xml' => AttachmentFixtures.content_types(
          '/xl/workbook.xml' => "#{main}.sheet.main+xml",
          '/xl/worksheets/sheet1.xml' => "#{main}.worksheet+xml"
        ),
        '_rels/.rels' => AttachmentFixtures.rels(
          'officeDocument' => 'xl/workbook.xml'
        ),
        'xl/workbook.xml' => %(<workbook #{ns}><sheets>) \
                             '<sheet name="Data" sheetId="1" r:id="rId1"/>' \
                             '</sheets></workbook>',
        'xl/_rels/workbook.xml.rels' => AttachmentFixtures.rels(
          'worksheet' => 'worksheets/sheet1.xml'
        ),
        'xl/worksheets/sheet1.xml' =>
          %(<worksheet #{ns}>#{"<cols>#{cols}</cols>" unless cols.empty?}) \
          "<sheetData>#{rows}</sheetData></worksheet>"
      )
    end

    def cell(ref, text)
      %(<c#{%( r="#{ref}") if ref} t="inlineStr"><is><t>#{text}</t></is></c>)
    end

    it 'treats a cell off Excel’s grid as hidden, without building a row out to it' do
      book = sheet_xlsx(%(<row r="1">) \
                        "#{cell('A1', 'Visible')}" \
                        "#{cell('ZZZZZZ1', 'Offgrid')}</row>")
      in_file(book, 'offgrid.xlsx') do |path|
        sheet = Disclosures::Sheets.read_xlsx(path).first
        expect(sheet.rows).to eq([['Visible']])
        expect(sheet).to have_attributes(hidden_cells: 1, total_columns: 1)
      end
    end

    it 'stops reading past its cap on cells read, references or not' do
      stub_const('Disclosures::Sheets::MAX_READ_CELLS', 50)
      book = sheet_xlsx(
        %(<row r="1">#{(1..60).map { |n| cell(nil, "v#{n}") }.join}</row>)
      )
      in_file(book, 'many.xlsx') do |path|
        expect { Disclosures::Sheets.read_xlsx(path) }.
          to raise_error(Disclosures::Error::Refused, /too large to read/)
      end
    end

    it 'reads thousands of overlapping hidden column ranges quickly and correctly' do
      far = "#{DocumentFixtures.column_letter(16_001)}1"
      cols = %(<col min="2" max="16000" hidden="1"/>) * 5_000
      book = sheet_xlsx(%(<row r="1">) \
                        "#{cell('A1', 'Visible')}#{cell('B1', 'Hidden')}" \
                        "#{cell(far, 'Far')}</row>",
                        cols: cols)
      in_file(book, 'cols.xlsx') do |path|
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        sheet = Disclosures::Sheets.read_xlsx(path).first
        expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).
          to be < 5
        expect(sheet.rows).to eq([%w[Visible Far]])
        expect(sheet.total_columns).to eq(2)
      end
    end
  end
end
