require_relative 'spec_helper'

RSpec.describe OfficePackage::ExcelMetadata do
  let(:fixtures) do
    Pathname(__dir__).join('../../excel_analyzer/spec/fixtures')
  end

  describe '.call' do
    it 'counts all hidden-data signals in a suspect workbook' do
      counts = described_class.call(File.binread(fixtures.join('suspect.xlsx')))
      expect(counts).to eq(
        data_model: 0,
        external_links: 1,
        hidden_columns: 2,
        hidden_rows: 2,
        hidden_sheets: 1,
        named_ranges: 1,
        pivot_cache: 1
      )
    end

    it 'returns zeros for a clean workbook' do
      counts = described_class.call(File.binread(fixtures.join('data.xlsx')))
      expect(counts).to eq(
        data_model: 0,
        external_links: 0,
        hidden_columns: 0,
        hidden_rows: 0,
        hidden_sheets: 0,
        named_ranges: 0,
        pivot_cache: 0
      )
    end

    it 'ignores Excel formula error cells (t="e") in hidden rows and columns' do
      sheet_xml = <<~XML
        <?xml version="1.0" encoding="UTF-8"?>
        <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
          <cols>
            <col min="2" max="3" hidden="1"/>
          </cols>
          <sheetData>
            <row r="1">
              <c r="A1" t="inlineStr"><is><t>ok</t></is></c>
              <c r="B1" t="e"><v>#REF!</v></c>
              <c r="C1"><v>42</v></c>
            </row>
            <row r="2" hidden="1">
              <c r="A2" t="e"><v>#N/A</v></c>
            </row>
            <row r="3" hidden="1">
              <c r="A3"><v>99</v></c>
            </row>
          </sheetData>
        </worksheet>
      XML
      bytes = OfficeFixtures.workbook(
        sheets: { 'xl/worksheets/sheet1.xml' => sheet_xml }
      )

      counts = described_class.call(bytes)
      expect(counts[:hidden_rows]).to eq(1)
      expect(counts[:hidden_columns]).to eq(1)
    end

    it 'excludes Excel built-in _xlnm.* defined names' do
      names = <<~XML
        <definedNames>
          <definedName name="_xlnm.Print_Area">Sheet1!$A$1:$B$2</definedName>
          <definedName name="_xlnm._FilterDatabase">Sheet1!$A$1:$B$2</definedName>
          <definedName name="StaffList">Sheet1!$A$1:$A$9</definedName>
        </definedNames>
      XML
      bytes = OfficeFixtures.workbook(workbook_extra: names)

      expect(described_class.call(bytes)[:named_ranges]).to eq(1)
    end

    it 'clamps huge hidden column ranges without blowing memory' do
      sheet_xml = <<~XML
        <?xml version="1.0" encoding="UTF-8"?>
        <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
          <cols>
            <col min="2" max="2147483647" hidden="1"/>
          </cols>
          <sheetData>
            <row r="1">
              <c r="A1"><v>1</v></c>
              <c r="B1"><v>2</v></c>
            </row>
          </sheetData>
        </worksheet>
      XML
      bytes = OfficeFixtures.workbook(
        sheets: { 'xl/worksheets/sheet1.xml' => sheet_xml }
      )

      expect(described_class.call(bytes)[:hidden_columns]).to eq(1)
    end

    it 'raises NotPackage for non-spreadsheet files' do
      expect { described_class.call('plain text') }.
        to raise_error(OfficePackage::NotPackage)
      docx = OfficeFixtures.word('<w:p><w:r><w:t>hello</w:t></w:r></w:p>')
      expect { described_class.call(docx) }.
        to raise_error(OfficePackage::NotPackage)
    end
  end

  describe '.embedded' do
    it 'finds embedded OOXML spreadsheets inside a Word document' do
      suspect = File.binread(fixtures.join('suspect.xlsx'))
      docx = OfficeFixtures.word(
        '<w:p><w:r><w:t>See chart</w:t></w:r></w:p>',
        parts: { 'word/embeddings/chart1.xlsx' => [nil, suspect] }
      )

      result = described_class.embedded(docx)
      expect(result[:errors]).to eq([])
      expect(result[:spreadsheets].size).to eq(1)
      expect(result[:spreadsheets].first[:part]).
        to eq('word/embeddings/chart1.xlsx')
      expect(result[:spreadsheets].first[:counts][:hidden_sheets]).to eq(1)
    end

    it 'yields embedded legacy .xls workbooks and ignores non-workbook OLE2' do
      suspect_xls = File.binread(fixtures.join('suspect.xls'))
      non_xls_ole = OfficeFixtures.compound({ 'WordDocument' => 'hello' })
      docx = OfficeFixtures.word(
        '<w:p><w:r><w:t>Embedded objects</w:t></w:r></w:p>',
        parts: {
          'word/embeddings/sheet.xls' => [nil, suspect_xls],
          'word/embeddings/doc.bin' => [nil, non_xls_ole]
        }
      )

      yielded = []
      result = described_class.embedded(docx) do |part, bytes|
        yielded << [part, bytes.bytesize]
      end
      expect(result[:errors]).to eq([])
      expect(result[:spreadsheets]).to eq([])
      expect(yielded).
        to eq([['word/embeddings/sheet.xls', suspect_xls.bytesize]])
    end

    it 'records an error for an encrypted embedded OLE2 file' do
      encrypted = OfficeFixtures.compound(
        { 'EncryptionInfo' => 'enc', 'EncryptedPackage' => 'pkg' }
      )
      docx = OfficeFixtures.word(
        '<w:p><w:r><w:t>Encrypted</w:t></w:r></w:p>',
        parts: { 'word/embeddings/locked.xls' => [nil, encrypted] }
      )

      result = described_class.embedded(docx)
      expect(result[:errors].size).to eq(1)
      expect(result[:errors].first[:error]).to include('encrypted')
    end

    it 'ignores invalid shared-string indices, huge refs and duplicate ' \
       'sheet references' do
      sst = '<?xml version="1.0" encoding="UTF-8"?>' \
            '<sst xmlns="http://schemas.openxmlformats.org/spreadsheetml/' \
            '2006/main"><si><t>value</t></si></sst>'
      huge = "#{'A' * 10_000}1"
      sheet = <<~XML
        <?xml version="1.0" encoding="UTF-8"?>
        <worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">
          <cols>
            <col min="1" max="16384" hidden="1"/>
            <col min="1" max="16384" hidden="1"/>
          </cols>
          <sheetData>
            <row r="1" hidden="1"><c r="A1" t="s"><v>-1</v></c></row>
            <row r="2" hidden="1"><c r="A2" t="s"><v></v></c></row>
            <row r="3" hidden="1"><c r="A3" t="s"><v>abc</v></c></row>
            <row r="4" hidden="1"><c r="A4" t="s"><v>0</v></c></row>
            <row r="5"><c r="#{huge}"><v>9</v></c></row>
          </sheetData>
        </worksheet>
      XML
      wb = OfficeFixtures.package(
        {
          '[Content_Types].xml' => OfficeFixtures.content_types(
            {
              'xl/workbook.xml' =>
                "#{OfficeFixtures::CT}spreadsheetml.sheet.main+xml",
              'xl/worksheets/sheet1.xml' =>
                "#{OfficeFixtures::CT}spreadsheetml.worksheet+xml",
              'xl/sharedStrings.xml' =>
                "#{OfficeFixtures::CT}spreadsheetml.sharedStrings+xml"
            }
          ),
          '_rels/.rels' => OfficeFixtures.rels(
            [['rId1', "#{OfficeFixtures::R}officeDocument", 'xl/workbook.xml']]
          ),
          'xl/workbook.xml' =>
            "#{OfficeFixtures::DECLARATION}<workbook #{OfficeFixtures::X}>" \
            '<sheets><sheet name="S1" sheetId="1" r:id="rIdS1"/>' \
            '<sheet name="S2" sheetId="2" r:id="rIdS1"/></sheets></workbook>',
          'xl/_rels/workbook.xml.rels' => OfficeFixtures.rels(
            [['rIdS1', "#{OfficeFixtures::R}worksheet",
              'worksheets/sheet1.xml'],
             ['rIdSS', "#{OfficeFixtures::R}sharedStrings",
              'sharedStrings.xml']]
          ),
          'xl/worksheets/sheet1.xml' => sheet,
          'xl/sharedStrings.xml' => sst
        }
      )

      counts = described_class.call(wb)
      expect(counts[:hidden_rows]).to eq(1)
      expect(counts[:hidden_columns]).to eq(1)
    end

    it 'caps nested embedded OOXML packages and records an error' do
      tiny = OfficeFixtures.workbook
      inner = OfficeFixtures.word(
        '<w:p/>',
        parts: (1..20).to_h { |i| ["word/embeddings/s#{i}.xlsx", [nil, tiny]] }
      )
      outer = OfficeFixtures.word(
        '<w:p/>',
        parts: (1..5).to_h { |i| ["word/embeddings/d#{i}.docx", [nil, inner]] }
      )

      result = described_class.embedded(outer)
      expect(result[:spreadsheets].size).
        to be <= OfficePackage::ExcelMetadata::MAX_EMBEDDED_PACKAGES
      expect(result[:errors].map { |e| e[:error] }).
        to include('too many embedded spreadsheets')
    end

    it 'records an error when embeddings remain at the depth limit, but ' \
       'allows a clean document at max depth' do
      suspect = File.binread(fixtures.join('suspect.xlsx'))
      clean_leaf = OfficeFixtures.word('<w:p><w:r><w:t>leaf</w:t></w:r></w:p>')
      clean_mid = OfficeFixtures.word(
        '<w:p/>', parts: { 'word/embeddings/leaf.docx' => [nil, clean_leaf] }
      )
      clean_outer = OfficeFixtures.word(
        '<w:p/>', parts: { 'word/embeddings/mid.docx' => [nil, clean_mid] }
      )
      expect(described_class.embedded(clean_outer)[:errors]).to eq([])

      deep_leaf = OfficeFixtures.word(
        '<w:p/>', parts: { 'word/embeddings/secret.xlsx' => [nil, suspect] }
      )
      deep_mid = OfficeFixtures.word(
        '<w:p/>', parts: { 'word/embeddings/leaf.docx' => [nil, deep_leaf] }
      )
      deep_outer = OfficeFixtures.word(
        '<w:p/>', parts: { 'word/embeddings/mid.docx' => [nil, deep_mid] }
      )
      deep_errors = described_class.embedded(deep_outer)[:errors]
      expect(deep_errors.map { |e| e[:error] }).
        to include('embedded files nested too deeply')
    end

    it 'detects password-encrypted OLE2 Office wrappers and ignores ' \
       'unencrypted non-workbook OLE2 files' do
      encrypted = OfficeFixtures.compound(
        { 'EncryptionInfo' => 'enc', 'EncryptedPackage' => 'pkg' }
      )
      enc_errors = described_class.embedded(encrypted)[:errors]
      expect(enc_errors.map { |e| e[:error] }).
        to include('encrypted Office document')

      legacy_doc = OfficeFixtures.compound({ 'WordDocument' => 'hello' })
      expect(described_class.embedded(legacy_doc)).
        to eq(spreadsheets: [], errors: [])
    end

    it 'follows internal embedding relationships stored outside /embeddings/ ' \
       'and enforces the depth limit on them' do
      suspect = File.binread(fixtures.join('suspect.xlsx'))
      docx = OfficeFixtures.word(
        '<w:p><w:r><w:t>Linked package</w:t></w:r></w:p>',
        document_rels: [['rIdPkg1', "#{OfficeFixtures::R}package",
                         'custom/opaque.bin']],
        parts: { 'word/custom/opaque.bin' =>
                 ['application/octet-stream', suspect] }
      )

      result = described_class.embedded(docx)
      expect(result[:errors]).to eq([])
      expect(result[:spreadsheets].size).to eq(1)
      expect(result[:spreadsheets].first[:part]).to eq('word/custom/opaque.bin')
      expect(result[:spreadsheets].first[:counts][:hidden_sheets]).to eq(1)

      deep_leaf = OfficeFixtures.word(
        '<w:p/>',
        document_rels: [['rIdPkg1', "#{OfficeFixtures::R}package",
                         'custom/opaque.bin']],
        parts: { 'word/custom/opaque.bin' =>
                 ['application/octet-stream', suspect] }
      )
      deep_mid = OfficeFixtures.word(
        '<w:p/>', parts: { 'word/embeddings/leaf.docx' => [nil, deep_leaf] }
      )
      deep_outer = OfficeFixtures.word(
        '<w:p/>', parts: { 'word/embeddings/mid.docx' => [nil, deep_mid] }
      )
      deep_errors = described_class.embedded(deep_outer)[:errors]
      expect(deep_errors.map { |e| e[:error] }).
        to include('embedded files nested too deeply')
    end

    it 'inspects modern OOXML workbooks stored inside OLE2 Package streams ' \
       'and applies depth and package limits' do
      suspect = File.binread(fixtures.join('suspect.xlsx'))
      ole_pkg = OfficeFixtures.compound({ 'Package' => suspect })
      docx = OfficeFixtures.word(
        '<w:p><w:r><w:t>OLE package</w:t></w:r></w:p>',
        parts: { 'word/embeddings/oleObject1.bin' => [nil, ole_pkg] }
      )

      result = described_class.embedded(docx)
      expect(result[:errors]).to eq([])
      expect(result[:spreadsheets].size).to eq(1)
      expect(result[:spreadsheets].first[:part]).
        to eq('word/embeddings/oleObject1.bin/Package')
      expect(result[:spreadsheets].first[:counts][:hidden_sheets]).to eq(1)

      top_result = described_class.embedded(ole_pkg)
      expect(top_result[:errors]).to eq([])
      expect(top_result[:spreadsheets].first[:counts][:hidden_sheets]).to eq(1)

      nested_ole = OfficeFixtures.compound(
        { 'Inner' => OfficeFixtures.compound({ 'Deep' => ole_pkg }) }
      )
      nested_errors = described_class.embedded(nested_ole)[:errors]
      expect(nested_errors.map { |e| e[:error] }).
        to include('embedded files nested too deeply')
    end

    it 'caps recorded embedding errors at MAX_EMBEDDED_PACKAGES' do
      encrypted = OfficeFixtures.compound(
        { 'EncryptionInfo' => 'enc', 'EncryptedPackage' => 'pkg' }
      )
      parts = (1..60).to_h do |i|
        ["word/embeddings/locked#{i}.bin", [nil, encrypted]]
      end
      docx = OfficeFixtures.word('<w:p/>', parts: parts)

      result = described_class.embedded(docx)
      expect(result[:errors].size).
        to eq(OfficePackage::ExcelMetadata::MAX_EMBEDDED_PACKAGES)
    end

    it 'ignores __MACOSX AppleDouble entries and fails closed on corrupt ' \
       'relationship XML' do
      apple_double = "\x00\x05\x16\x07\x00\x02\x00\x00".b
      docx = OfficeFixtures.word(
        '<w:p><w:r><w:t>Mac archive</w:t></w:r></w:p>',
        parts: {
          '__MACOSX/word/._document.xml' => [nil, apple_double],
          '__MACOSX/word/_rels/._document.xml.rels' => [nil, apple_double]
        }
      )
      expect(described_class.embedded(docx)).to eq(spreadsheets: [], errors: [])

      broken = OfficeFixtures.word(
        '<w:p/>',
        parts: { 'word/_rels/document.xml.rels' => [nil, '<broken'] }
      )
      broken_errors = described_class.embedded(broken)[:errors]
      expect(broken_errors.map { |e| e[:part] }).
        to include('word/_rels/document.xml.rels')
    end

    it 'inspects workbooks wrapped in OLE10Native streams and fails closed ' \
       'on unreadable Office OLE10Native payloads' do
      ole10 = ->(label, payload) do
        lbl = "#{label}\0".b
        cmd = "C:\\#{label}\0".b
        body = [2].pack('v') + lbl + cmd + [0, 3].pack('vv') +
               [cmd.bytesize].pack('V') + cmd +
               [payload.bytesize].pack('V') + payload.b
        [body.bytesize].pack('V') + body
      end
      suspect = File.binread(fixtures.join('suspect.xlsx'))
      ole = OfficeFixtures.compound(
        { "\u0001Ole10Native" => ole10.call('secret.xlsx', suspect) }
      )
      docx = OfficeFixtures.word(
        '<w:p/>',
        parts: { 'word/embeddings/oleObject1.bin' => [nil, ole] }
      )
      res = described_class.embedded(docx)
      expect(res[:errors]).to eq([])
      expect(res[:spreadsheets].first[:counts][:hidden_sheets]).to eq(1)

      trunc_body = [2].pack('v') + "secret.xlsx\0".b + "C:\\x\0".b
      trunc_ole = OfficeFixtures.compound(
        { "\u0001Ole10Native" => [trunc_body.bytesize].pack('V') + trunc_body }
      )
      trunc_docx = OfficeFixtures.word(
        '<w:p/>',
        parts: { 'word/embeddings/oleObject1.bin' => [nil, trunc_ole] }
      )
      trunc_errors = described_class.embedded(trunc_docx)[:errors]
      expect(trunc_errors.map { |e| e[:error] }).
        to include('unreadable embedded Office file')
    end
  end
end
