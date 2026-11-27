require_relative 'spec_helper'

RSpec.describe OfficePackage::Detector do
  let(:r) { OfficeFixtures::R }
  let(:ct) { OfficeFixtures::CT }
  let(:jane) { ->(text) { text.include?('Jane Example') } }

  def detect(bytes, matcher = jane)
    described_class.call(bytes, matcher)
  end

  def hit_parts(bytes, matcher = jane)
    detect(bytes, matcher).hits.map(&:part).uniq
  end

  it 'finds nothing in a file without the words' do
    fleet = OfficeFixtures.word('<w:p><w:r><w:t>Fleet</w:t></w:r></w:p>',
                                core: nil)
    expect(detect(fleet)).not_to be_match
    # The fixture's properties name her.
    expect(hit_parts(OfficeFixtures.word('<w:p/>'))).
      to eq(['docProps/core.xml'])
  end

  it 'finds text nodes and attribute values in any part' do
    expect(hit_parts(OfficeFixtures.word(
                       '<w:p/>',
                       core: nil,
                       parts: { 'docProps/custom.xml' =>
                                  [nil, '<p><v>Jane Example</v></p>'] }
                     ))).to eq(['docProps/custom.xml'])
    expect(hit_parts(OfficeFixtures.word(
                       '<w:p><w:r><w:drawing><wp:docPr xmlns:wp="urn:wp" ' \
                       'descr="Photo of Jane Example"/>' \
                       '</w:drawing></w:r></w:p>', core: nil
                     ))).to eq(['word/document.xml'])
  end

  it 'finds words split across runs and across the cells of a row' do
    split = '<w:p><w:r><w:t xml:space="preserve">Jane </w:t></w:r>' \
            '<w:r><w:rPr><w:b/></w:rPr><w:t>Example</w:t></w:r></w:p>'
    expect(detect(OfficeFixtures.word(split, core: nil)).hits).
      to eq([described_class::Hit.new(part: 'word/document.xml',
                                      where: 'blocks')])
    staff = OfficeFixtures.workbook(
      sheets: {
        'xl/worksheets/sheet1.xml' =>
          OfficeFixtures.sheet_xml([%w[First Last], %w[Jane Example]])
      },
      core: nil
    )
    expect(hit_parts(staff)).to eq(['xl/worksheets/sheet1.xml'])
    table = '<w:tbl><w:tr><w:tc><w:p><w:r><w:t>Jane</w:t></w:r></w:p></w:tc>' \
            '<w:tc><w:p><w:r><w:t>Example</w:t></w:r></w:p></w:tc>' \
            '</w:tr></w:tbl>'
    expect(hit_parts(OfficeFixtures.word(table, core: nil))).
      to eq(['word/document.xml'])
  end

  it 'fills in shared strings in a row' do
    shared = "<sst #{OfficeFixtures::X}><si><t>Jane</t></si><si><t>Example" \
             '</t></si></sst>'
    sheet = "#{OfficeFixtures::DECLARATION}<worksheet #{OfficeFixtures::X}>" \
            '<sheetData><row r="1"><c r="A1" t="s"><v>0</v></c>' \
            '<c r="B1" t="s"><v>1</v></c></row></sheetData></worksheet>'
    bytes = OfficeFixtures.workbook(
      sheets: { 'xl/worksheets/sheet1.xml' => sheet }, core: nil,
      workbook_rels: [['rIdT', "#{r}sharedStrings", 'sharedStrings.xml']],
      parts: { 'xl/sharedStrings.xml' =>
                 ["#{ct}spreadsheetml.sharedStrings+xml", shared] }
    )
    expect(hit_parts(bytes)).to eq(['xl/worksheets/sheet1.xml'])
  end

  it 'reads tracked text without deletions and without insertions' do
    body = '<w:p><w:r><w:t xml:space="preserve">Jane </w:t></w:r>' \
           '<w:del><w:r><w:delText>Smith</w:delText></w:r></w:del>' \
           '<w:ins><w:r><w:t>Example</w:t></w:r></w:ins></w:p>' \
           '<w:p><w:r><w:t xml:space="preserve">John </w:t></w:r>' \
           '<w:ins><w:r><w:t>Q. </w:t></w:r></w:ins>' \
           '<w:r><w:t>Sample</w:t></w:r></w:p>'
    bytes = OfficeFixtures.word(body, core: nil)
    expect(detect(bytes)).to be_match
    expect(detect(bytes, ->(text) { text.include?('Jane Smith') })).to be_match
    expect(detect(bytes, ->(text) { text.include?('John Sample') })).to be_match
  end

  it 'finds words in XML comments and processing instructions' do
    commented = OfficeFixtures.word('<!-- Jane Example --><w:p/>', core: nil)
    expect(hit_parts(commented)).to eq(['word/document.xml'])
    instruction = OfficeFixtures.word('<?note Jane Example?><w:p/>', core: nil)
    expect(hit_parts(instruction)).to eq(['word/document.xml'])
  end

  it 'leaves out structural attributes' do
    numbers = ->(text) { text.include?('00AB12CD') }
    body = '<w:p w:rsidR="00AB12CD"><w:r><w:t>Fleet</w:t></w:r></w:p>'
    expect(detect(OfficeFixtures.word(body, core: nil), numbers)).
      not_to be_match
  end

  it 'reads streams of an embedded compound file by their chains' do
    stream = "#{'x' * 506}Jane Example#{'y' * 4000}"
    ole = OfficeFixtures.compound({ "\u0001Ole10Native" => stream },
                                  scramble: true)
    bytes = OfficeFixtures.word(
      '<w:p/>', core: nil,
                parts: { 'word/embeddings/oleObject1.bin' => [nil, ole] }
    )
    expect(hit_parts(bytes)).to eq(['word/embeddings/oleObject1.bin/' \
                                    "\u0001Ole10Native"])
  end

  it 'reads Office files embedded in it, to two levels' do
    inner = OfficeFixtures.workbook(
      sheets: { 'xl/worksheets/sheet1.xml' =>
                  OfficeFixtures.sheet_xml([['Jane Example']]) },
      core: nil
    )
    bytes = OfficeFixtures.word(
      '<w:p/>',
      core: nil,
      parts: {
        'word/embeddings/Microsoft_Excel_Worksheet.xlsx' => [nil, inner]
      }
    )
    expect(hit_parts(bytes)).
      to eq(['word/embeddings/Microsoft_Excel_Worksheet.xlsx/' \
             'xl/worksheets/sheet1.xml'])
  end

  it 'reads strings in other binary parts, part names, and what is outside the parts' do
    expect(hit_parts(OfficeFixtures.word(
                       '<w:p/>', core: nil,
                                 parts: { 'word/printerSettings1.bin' =>
                 [nil, "\x00\x01Jane Example\x00".b] }
                     ))).to eq(['word/printerSettings1.bin'])
    wide = 'Jane Example'.encode('UTF-16LE').b
    expect(hit_parts(OfficeFixtures.word(
                       '<w:p/>',
                       core: nil,
                       parts: { 'word/data.bin' => [nil, "\x05#{wide}".b] }
                     ))).to eq(['word/data.bin'])
    expect(hit_parts(OfficeFixtures.word(
                       '<w:p/>',
                       core: nil,
                       parts: { 'word/Jane Example.xml' => [nil, '<x/>'] }
                     ))).to eq(['part names'])
    expect(hit_parts(OfficeFixtures.word('<w:p/>', core: nil,
                                                   between: 'Jane Example'))).
      to eq(['outside the parts'])
    expect(hit_parts(OfficeFixtures.word('<w:p/>', core: nil,
                                                   comment: 'Jane Example'))).
      to eq(['outside the parts'])
    wide = "Jane O\u2019Example".encode('UTF-16LE').b
    expect(
      OfficePackage::Detector.call(
        OfficeFixtures.word(
          '<w:p/>', core: nil,
                    parts: { 'word/data.bin' => [nil, "\x05#{wide}".b] }
        ),
        ->(t) { t.include?("Jane O\u2019Example") }
      ).hits.map(&:part)
    ).to eq(['word/data.bin'])
  end

  it 'lists what it can’t read' do
    result = detect(OfficeFixtures.word(
                      '<w:p/>',
                      core: nil,
                      parts: { 'word/media/image1.png' =>
                                 [nil, "\x89PNGJane Example".b] }
                    ))
    expect(result).not_to be_match
    expect(result.not_checked).to eq(['word/media/image1.png'])
  end

  it 'refuses a part that declares a DOCTYPE, including in UTF-16' do
    ['<!DOCTYPE x [<!ENTITY e "y">]><x>&e;</x>',
     "\xFF\xFE".b + '<!DOCTYPE x><x/>'.encode('UTF-16LE').b].each do |xml|
      bytes = OfficeFixtures.word(
        '<w:p/>', core: nil, parts: { 'word/x.xml' => [nil, xml] }
      )
      expect { detect(bytes) }.
        to raise_error(OfficePackage::Refused, /DOCTYPE/)
    end
  end
end
