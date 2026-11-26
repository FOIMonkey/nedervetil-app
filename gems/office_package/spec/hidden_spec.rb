require_relative 'spec_helper'

RSpec.describe OfficePackage::Hidden do
  let(:r) { OfficeFixtures::R }
  let(:ct) { OfficeFixtures::CT }

  def items(bytes)
    described_class.call(bytes).to_h { |item| [item.type, item] }
  end

  describe 'a workbook' do
    it 'reads the text of hidden sheets, rows and columns, and not what shows' do
      shared = "<sst #{OfficeFixtures::X}><si><t>Jane Example</t></si>" \
               '<si><r><t>Invest</t></r><r><t>igator</t></r></si></sst>'
      staff = "#{OfficeFixtures::DECLARATION}<worksheet #{OfficeFixtures::X}>" \
              '<sheetData><row r="1"><c r="A1" t="s"><v>0</v></c>' \
              '<c r="B1" t="s"><v>1</v></c><c r="C1"><v>42</v></c></row>' \
              '</sheetData></worksheet>'
      found = items(OfficeFixtures.workbook(
                      sheets: {
                        'xl/worksheets/sheet1.xml' => OfficeFixtures.sheet_xml(
                          [%w[Depot Vans Note],
                           ['North', '12', 'Ask John Sample']],
                          hidden_rows: [2],
                          before: '<cols><col min="3" max="3" hidden="1"/>' \
                                  '</cols>'
                        ),
                        'xl/worksheets/sheet2.xml' => staff,
                        'xl/worksheets/sheet3.xml' =>
                          OfficeFixtures.sheet_xml([%w[Secret]])
                      },
                      states: { 2 => 'hidden', 3 => 'veryHidden' },
                      workbook_rels: [['rIdT', "#{r}sharedStrings",
                                       'sharedStrings.xml']],
                      parts: { 'xl/sharedStrings.xml' =>
                                 ["#{ct}spreadsheetml.sharedStrings+xml",
                                  shared] }
                    ))
      expect(found['hidden_rows']).to have_attributes(
        name: 'Sheet1', count: 1, texts: ['North', '12', 'Ask John Sample'],
        readable: true
      )
      expect(found['hidden_columns']).
        to have_attributes(name: 'Sheet1', count: 1, texts: ['Note'])
      expect(found['hidden_sheet']).
        to have_attributes(name: 'Sheet2',
                           texts: ['Jane Example', 'Investigator'])
      expect(found['very_hidden_sheet']).
        to have_attributes(name: 'Sheet3', texts: ['Secret'])
    end

    it 'says it can’t read a data model, and counts names and links' do
      found = items(OfficeFixtures.workbook(
                      workbook_extra:
                        '<definedNames><definedName name="Staff">' \
                        'Sheet1!$A$1</definedName><definedName ' \
                        'name="_xlnm.Print_Area">Sheet1!$A$1</definedName>' \
                        '</definedNames>',
                      workbook_rels: [
                        # rubocop:disable Layout/LineLength -- a URL
                        ['rIdM', 'http://schemas.microsoft.com/office/2006/relationships/' \
                                 'xlDataModel', 'model/item.data'],
                        # rubocop:enable Layout/LineLength
                        ['rIdL', "#{r}externalLink",
                         'externalLinks/externalLink1.xml']
                      ],
                      parts: {
                        'xl/model/item.data' => [nil, "\x00binary".b],
                        'xl/externalLinks/externalLink1.xml' =>
                          ["#{ct}spreadsheetml.externalLink+xml",
                           '<externalLink/>']
                      }
                    ))
      expect(found['data_model']).to have_attributes(readable: false)
      expect(found['named_ranges']).to have_attributes(count: 1)
      expect(found['external_links']).to have_attributes(count: 1)
    end

    it 'reads the pivot caches Tidy kept' do
      definition = '<pivotCacheDefinition><cacheFields><cacheField ' \
                   'name="Name"><sharedItems><s v="Jane Example"/>' \
                   '<s v="John Sample"/></sharedItems></cacheField>' \
                   '</cacheFields></pivotCacheDefinition>'
      found = items(OfficeFixtures.workbook(
                      workbook_rels: [['rIdC', "#{r}pivotCacheDefinition",
                                       'pivotCache/pivotCacheDefinition1.xml']],
                      parts: {
                        'xl/pivotCache/pivotCacheDefinition1.xml' =>
                          ["#{ct}spreadsheetml.pivotCacheDefinition+xml",
                           definition]
                      }
                    ))
      expect(found['pivot_caches']).
        to have_attributes(count: 1, texts: ['Jane Example', 'John Sample'])
    end
  end

  describe 'a Word file' do
    it 'reads hidden text, directly or by style, and stored building blocks' do
      w = OfficeFixtures::W
      styles = "<w:styles #{w}><w:style w:styleId=\"Secret\"><w:rPr>" \
               '<w:vanish/></w:rPr></w:style></w:styles>'
      glossary = "<w:glossaryDocument #{w}><w:docParts><w:docPart>" \
                 '<w:docPartBody><w:p><w:r><w:t>Signed Jane Example</w:t>' \
                 '</w:r></w:p></w:docPartBody></w:docPart></w:docParts>' \
                 '</w:glossaryDocument>'
      found = items(OfficeFixtures.word(
                      '<w:p><w:r><w:rPr><w:vanish/></w:rPr>' \
                      '<w:t>Direct</w:t></w:r>' \
                      '<w:r><w:rPr><w:vanish w:val="0"/></w:rPr>' \
                      '<w:t>Shown</w:t></w:r></w:p>' \
                      '<w:p><w:pPr><w:pStyle w:val="Secret"/></w:pPr>' \
                      '<w:r><w:t>By style</w:t></w:r></w:p>',
        core: nil,
        document_rels: [['rId1', "#{r}styles", 'styles.xml'],
                        ['rId2', "#{r}glossaryDocument",
                         'glossary/document.xml']],
        parts: {
          'word/styles.xml' => ["#{ct}wordprocessingml.styles+xml", styles],
          'word/glossary/document.xml' =>
            ["#{ct}wordprocessingml.document.glossary+xml", glossary]
        }
                    ))
      expect(found['hidden_text']).
        to have_attributes(count: 2, texts: ['Direct', 'By style'])
      expect(found['building_blocks']).
        to have_attributes(count: 1, texts: ['Signed Jane Example'])
    end
  end

  describe 'a presentation' do
    it 'reads hidden slides, text off the slide and speaker notes with words in' do
      p_ns = OfficeFixtures::P
      slide = ->(show, shapes) do
        visible = show ? '' : ' show="0"'
        sp = shapes.map do |x, text|
          '<p:sp><p:spPr><a:xfrm><a:off x="' + x.to_s + '" y="100"/>' \
            '<a:ext cx="100" cy="100"/></a:xfrm></p:spPr><p:txBody><a:p>' \
            "<a:r><a:t>#{text}</a:t></a:r></a:p></p:txBody></p:sp>"
        end.join
        "<p:sld #{p_ns}#{visible}><p:cSld><p:spTree>#{sp}</p:spTree>" \
          '</p:cSld></p:sld>'
      end
      notes = ->(text) do
        "<p:notes #{p_ns}><a:p><a:r><a:t>#{text}</a:t></a:r></a:p></p:notes>"
      end
      deck = OfficeFixtures.deck(
        extra: '<p:sldSz cx="9144" cy="6858"/>',
        slides: {
          'ppt/slides/slide1.xml' => slide.call(true, [[100, 'Depots'],
                                                       [99_999, 'Off it']]),
          'ppt/slides/slide2.xml' => slide.call(false, [[100, 'Hidden one']])
        },
        slide_rels: {
          'ppt/slides/slide1.xml' => [['rIdN', "#{r}notesSlide",
                                       '../notesSlides/notesSlide1.xml']],
          'ppt/slides/slide2.xml' => [['rIdN', "#{r}notesSlide",
                                       '../notesSlides/notesSlide2.xml']]
        },
        parts: {
          'ppt/notesSlides/notesSlide1.xml' =>
            ["#{ct}presentationml.notesSlide+xml", notes.call('Tell Jane')],
          'ppt/notesSlides/notesSlide2.xml' =>
            ["#{ct}presentationml.notesSlide+xml", notes.call(' ')]
        }
      )
      found = items(deck)
      expect(found['hidden_slides']).to have_attributes(count: 1,
                                                        texts: ['Hidden one'])
      expect(found['off_slide_text']).to have_attributes(count: 1,
                                                         texts: ['Off it'])
      expect(found['speaker_notes']).to have_attributes(count: 1,
                                                        texts: ['Tell Jane'])
    end
  end

  describe 'every kind' do
    it 'reads a chart’s own workbook, and can’t read other embedded files' do
      inner = OfficeFixtures.workbook(
        sheets: { 'xl/worksheets/sheet1.xml' =>
                    OfficeFixtures.sheet_xml([['Jane Example', '3']]) },
        core: nil
      )
      found = items(OfficeFixtures.workbook(
                      core: nil,
                      workbook_rels: [['rIdD', "#{r}drawing",
                                       'drawings/drawing1.xml']],
                      parts: {
                        'xl/drawings/drawing1.xml' =>
                          ["#{ct}drawing+xml",
                           '<xdr:wsDr xmlns:xdr="urn:x"/>'],
                        'xl/drawings/_rels/drawing1.xml.rels' =>
                          [nil, OfficeFixtures.rels(
                            [['rIdC', "#{r}chart", '../charts/chart1.xml']]
                          )],
                        'xl/charts/chart1.xml' =>
                          ["#{ct}drawingml.chart+xml",
                           '<c:chartSpace xmlns:c="urn:c"/>'],
                        'xl/charts/_rels/chart1.xml.rels' =>
                          [nil, OfficeFixtures.rels(
                            [['rId1', "#{r}package",
                              '../embeddings/Microsoft_Excel_Worksheet.xlsx']]
                          )],
                        'xl/embeddings/Microsoft_Excel_Worksheet.xlsx' =>
                          [nil, inner],
                        'xl/embeddings/oleObject1.bin' =>
                          [nil, "\xD0\xCF\x11\xE0rest".b]
                      },
                      defaults: {
                        'xlsx' => 'application/vnd.openxmlformats-' \
                                  'officedocument.spreadsheetml.sheet',
                        'bin' => "#{ct}oleObject"
                      }
                    ))
      expect(found['chart_data']).
        to have_attributes(count: 1, texts: ['Jane Example', '3'],
                           readable: true)
      expect(found['embedded_files']).to have_attributes(count: 1,
                                                         readable: false)
    end

    it 'notes macros and the title' do
      found = items(OfficeFixtures.word(
                      '<w:p/>',
        document_rels: [['rIdV', 'http://schemas.microsoft.com/office/2006/' \
                                 'relationships/vbaProject', 'vbaProject.bin']],
        parts: { 'word/vbaProject.bin' => [
          'application/vnd.ms-office.vbaProject', 'x'
        ] }
                    ))
      expect(found['macros']).not_to be_nil
      expect(found['title']).to have_attributes(texts: ['Fleet report'])
    end
  end
end
