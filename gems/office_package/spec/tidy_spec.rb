require_relative 'spec_helper'

RSpec.describe OfficePackage::Tidy do
  include OfficeFixtures

  let(:r) { OfficeFixtures::R }
  let(:ct) { OfficeFixtures::CT }

  def tidy(bytes)
    described_class.call(bytes)
  end

  # The zip with field added as an extra field to its first entry, local and
  # central, offsets moved to match.
  def add_extra(bytes, field)
    bytes = bytes.b
    first_name = bytes.unpack1('@26v')
    local = bytes.byteslice(0, 28) + [field.bytesize].pack('v') +
            bytes.byteslice(30, first_name) + field
    rest = bytes.byteslice(30 + first_name, bytes.bytesize)
    out = local + rest
    shift = field.bytesize
    directory = out.index("PK\x01\x02".b)
    position = directory
    first = true
    while out.unpack1("@#{position}V") == 0x02014b50
      name, extra, comment = out.unpack("@#{position + 28}vvv")
      offset = out.unpack1("@#{position + 42}V")
      out[position + 42, 4] = [offset + shift].pack('V') unless offset.zero?
      if first
        out[position + 30, 2] = [extra + field.bytesize].pack('v')
        out.insert(position + 46 + name, field)
        extra += field.bytesize
        first = false
      end
      position += 46 + name + extra + comment
    end
    eocd = out.rindex("PK\x05\x06".b)
    size, start = out.unpack("@#{eocd + 12}VV")
    out[eocd + 12, 8] = [size + field.bytesize, start + shift].pack('VV')
    out
  end

  def word_text(xml)
    Nokogiri::XML(xml).xpath('//w:p', 'w' => OfficePackage::WORD_NS.first).
      map do |paragraph|
        paragraph.xpath('.//w:t', 'w' => OfficePackage::WORD_NS.first).
          map(&:text).join
      end
  end

  describe 'a Word file' do
    it 'accepts tracked changes' do
      body = '<w:p><w:r><w:t xml:space="preserve">Keep </w:t></w:r>' \
             '<w:del w:id="1" w:author="Jane Example"><w:r>' \
             '<w:delText>gone </w:delText></w:r></w:del>' \
             '<w:ins w:id="2" w:author="Jane Example"><w:r><w:t>added</w:t>' \
             '</w:r></w:ins></w:p>' \
             '<w:p><w:pPr><w:rPr><w:del w:id="3" w:author="Jane Example"/>' \
             '</w:rPr></w:pPr><w:r><w:t xml:space="preserve">Joined </w:t>' \
             '</w:r></w:p>' \
             '<w:p><w:pPr><w:jc w:val="center"/></w:pPr><w:r>' \
             '<w:t>to the next</w:t></w:r></w:p>' \
             '<w:p><w:pPr><w:rPr><w:ins w:id="4" w:author="J"/></w:rPr>' \
             '</w:pPr><w:moveFromRangeStart w:id="5" w:name="m"/>' \
             '<w:moveFrom w:id="6" w:author="J"><w:r><w:t>moved away</w:t>' \
             '</w:r></w:moveFrom><w:moveFromRangeEnd w:id="5"/></w:p>' \
             '<w:p><w:moveTo w:id="7" w:author="J"><w:r><w:t>moved here</w:t>' \
             '</w:r></w:moveTo><w:r><w:rPr><w:b/><w:rPrChange w:id="8" ' \
             'w:author="J"><w:rPr/></w:rPrChange></w:rPr><w:t>bold</w:t>' \
             '</w:r></w:p>' \
             '<w:tbl><w:tr><w:tc><w:p><w:r><w:t>kept row</w:t></w:r></w:p>' \
             '</w:tc></w:tr><w:tr><w:trPr><w:del w:id="9" w:author="J"/>' \
             '</w:trPr><w:tc><w:p><w:r><w:t>deleted row</w:t></w:r></w:p>' \
             '</w:tc></w:tr></w:tbl>'
      result = tidy(OfficeFixtures.word(body, core: nil))
      document = OfficeFixtures.parts(result.bytes)['word/document.xml']
      expect(word_text(document)).to eq(
        ['Keep added', 'Joined to the next', '', 'moved herebold', 'kept row']
      )
      expect(document).to include('<w:jc w:val="center"/>')
      expect(document).not_to match(/w:(?:ins|del|moveFrom|moveTo|rPrChange)\b/)
      expect(document).not_to include('gone', 'moved away', 'deleted row',
                                      'Jane Example')
      expect(result.removed).to eq('tracked_changes' => 8)
    end

    it 'accepts tracked formatting changes in styles too' do
      styles = "#{OfficeFixtures::DECLARATION}<w:styles #{OfficeFixtures::W}>" \
               '<w:style w:styleId="Normal"><w:rPr><w:b/><w:rPrChange ' \
               'w:id="1" w:author="Jane Example"><w:rPr/></w:rPrChange>' \
               '</w:rPr></w:style></w:styles>'
      result = tidy(OfficeFixtures.word(
                      '<w:p/>',
                      core: nil,
                      document_rels: [['rId9', "#{r}styles", 'styles.xml']],
                      parts: {
                        'word/styles.xml' =>
                          ["#{ct}wordprocessingml.styles+xml", styles]
                      }
                    ))
      expect(OfficeFixtures.parts(result.bytes)['word/styles.xml']).
        not_to include('rPrChange', 'Jane')
      expect(result.removed).to eq('tracked_changes' => 1)
    end

    it 'removes comments, their anchors and their authors, keeping the ' \
       'commented text' do
      comments = "#{OfficeFixtures::DECLARATION}<w:comments " \
                 "#{OfficeFixtures::W}><w:comment w:id=\"0\" " \
                 'w:author="Jane Example"><w:p><w:r><w:t>Check with Jane' \
                 '</w:t></w:r></w:p></w:comment><w:comment w:id="1"/>' \
                 '</w:comments>'
      body = '<w:p><w:commentRangeStart w:id="0"/><w:r><w:t>Commented' \
             '</w:t></w:r><w:commentRangeEnd w:id="0"/><w:r><w:rPr>' \
             '<w:rStyle w:val="CommentReference"/></w:rPr>' \
             '<w:commentReference w:id="0"/></w:r></w:p>'
      result = tidy(OfficeFixtures.word(
                      body,
                      core: nil,
                      document_rels: [
                        ['rId1', "#{r}comments", 'comments.xml'],
                        ['rId2', "#{OfficeFixtures::MS2011}commentsExtended",
                         'commentsExtended.xml'],
                        ['rId3', "#{OfficeFixtures::MS2011}people",
                         'people.xml']
                      ],
                      parts: {
                        'word/comments.xml' =>
                          ["#{ct}wordprocessingml.comments+xml", comments],
                        'word/commentsExtended.xml' =>
                          ["#{ct}wordprocessingml.commentsExtended+xml",
                           '<x/>'],
                        'word/people.xml' =>
                          ["#{ct}wordprocessingml.people+xml",
                           '<w15:people xmlns:w15="urn:w15"/>']
                      }
                    ))
      out = OfficeFixtures.parts(result.bytes)
      expect(out.keys).not_to include('word/comments.xml',
                                      'word/commentsExtended.xml',
                                      'word/people.xml')
      expect(word_text(out['word/document.xml'])).to eq(['Commented'])
      expect(out['word/document.xml']).not_to include('comment')
      expect(out['word/_rels/document.xml.rels']).not_to include('rId')
      expect(out['[Content_Types].xml']).not_to include('comments', 'people')
      expect(result.removed).to eq('comments' => 2, 'author_lists' => 1)
    end

    it 'keeps only the title, dates and language of the properties' do
      settings = "#{OfficeFixtures::DECLARATION}<w:settings " \
                 "#{OfficeFixtures::W}><w:trackRevisions/>" \
                 '<w:attachedTemplate r:id="rIdT"/><w:mailMerge>' \
                 '<w:dataSource r:id="rIdM"/></w:mailMerge><w:docVars>' \
                 '<w:docVar w:name="owner" w:val="Jane Example"/>' \
                 '</w:docVars><w:zoom w:percent="100"/></w:settings>'
      bytes = OfficeFixtures.word(
        '<w:p><w:r><w:t>Text</w:t></w:r></w:p>',
        package_rels: [
          ['rId3', "#{r}extended-properties", 'docProps/app.xml'],
          ['rId4', "#{r}custom-properties", 'docProps/custom.xml'],
          ['rId5', "#{OfficeFixtures::META}thumbnail",
           'docProps/thumbnail.jpeg']
        ],
        document_rels: [['rId1', "#{r}settings", 'settings.xml']],
        defaults: { 'jpeg' => 'image/jpeg' },
        parts: {
          'docProps/app.xml' => ["#{ct}extended-properties+xml",
                                 '<Properties><Company>Council</Company>' \
                                 '</Properties>'],
          'docProps/custom.xml' => ["#{ct}custom-properties+xml",
                                    '<Properties/>'],
          'docProps/thumbnail.jpeg' => [nil, "\xFF\xD8\xFF".b],
          'word/settings.xml' => ["#{ct}wordprocessingml.settings+xml",
                                  settings],
          'word/_rels/settings.xml.rels' => [nil, OfficeFixtures.rels(
            [['rIdT', "#{r}attachedTemplate",
              'file:///C:\\Users\\jexample\\Normal.dotm', 'External'],
             ['rIdM', "#{r}mailMergeSource",
              'file:///C:\\Users\\jexample\\list.xlsx', 'External']]
          )]
        }
      )
      result = tidy(bytes)
      out = OfficeFixtures.parts(result.bytes)
      expect(out.keys).not_to include('docProps/app.xml', 'docProps/custom.xml',
                                      'docProps/thumbnail.jpeg')
      expect(out['docProps/core.xml']).to include('Fleet report', '2026-01-02')
      expect(out['docProps/core.xml']).not_to include('Jane', 'internal')
      expect(out['word/settings.xml']).to include('w:zoom')
      expect(out['word/settings.xml']).
        not_to include('Jane', 'attachedTemplate', 'mailMerge',
                       'trackRevisions')
      expect(out['word/_rels/settings.xml.rels']).not_to include('jexample')
      expect(out['_rels/.rels']).
        not_to include('extended-properties', 'custom-properties', 'thumbnail')
      expect(result.removed).to eq('properties' => 1, 'thumbnail' => 1)
    end

    it 'removes custom XML and unbinds the content controls that showed it' do
      body = '<w:sdt><w:sdtPr><w:dataBinding w:xpath="/root/name" ' \
             'w:storeItemID="{1}"/></w:sdtPr><w:sdtContent><w:p><w:r>' \
             '<w:t>Shown name</w:t></w:r></w:p></w:sdtContent></w:sdt>'
      result = tidy(OfficeFixtures.word(
                      body,
                      core: nil,
                      document_rels: [['rId1', "#{r}customXml",
                                       '../customXml/item1.xml']],
                      parts: {
                        'customXml/item1.xml' =>
                          [nil, '<root><name>Jane Example</name></root>'],
                        'customXml/itemProps1.xml' =>
                          ["#{ct}customXmlProperties+xml",
                           '<ds:datastoreItem xmlns:ds="urn:ds"/>'],
                        'customXml/_rels/item1.xml.rels' =>
                          [nil, OfficeFixtures.rels(
                            [['rId1', "#{r}customXmlProps", 'itemProps1.xml']]
                          )]
                      }
                    ))
      out = OfficeFixtures.parts(result.bytes)
      expect(out.keys.grep(/customXml/i)).to be_empty
      expect(word_text(out['word/document.xml'])).to eq(['Shown name'])
      expect(out['word/document.xml']).not_to include('dataBinding')
      expect(result.removed).to eq('custom_xml' => 1)
    end

    it 'removes comment parts however they are reached' do
      header = "#{OfficeFixtures::DECLARATION}<w:hdr #{OfficeFixtures::W}>" \
               '<w:p><w:r><w:t>Header</w:t></w:r></w:p></w:hdr>'
      result = tidy(OfficeFixtures.word(
                      '<w:p/>',
                      core: nil,
                      document_rels: [['rId1', "#{r}header", 'header1.xml']],
                      parts: {
                        'word/header1.xml' => [
                          "#{ct}wordprocessingml.header+xml", header
                        ],
                        'word/_rels/header1.xml.rels' =>
                          [nil, OfficeFixtures.rels(
                            [['rId1', "#{r}comments", 'comments.xml']]
                          )],
                        'word/comments.xml' =>
                          ["#{ct}wordprocessingml.comments+xml",
                           "<w:comments #{OfficeFixtures::W}/>"]
                      }
                    ))
      expect(OfficeFixtures.parts(result.bytes).keys).
        not_to include('word/comments.xml')
      expect(result.removed).to eq('comments' => 1)
    end

    it 'removes comments left in the XML, in any part' do
      bytes = OfficeFixtures.word(
        '<!-- Jane Example drafted this --><w:p><w:r><w:t>Text</w:t>' \
        '</w:r></w:p><!-- check with Jane -->',
        core: nil,
        document_rels: [['rId1', "#{r}settings", 'settings.xml']],
        parts: {
          'word/settings.xml' => [
            "#{ct}wordprocessingml.settings+xml",
            "<w:settings #{OfficeFixtures::W}><!-- note --></w:settings>"
          ]
        }
      )
      result = tidy(bytes)
      out = OfficeFixtures.parts(result.bytes)
      expect(out.values.join).not_to include('<!--', 'Jane')
      expect(word_text(out['word/document.xml'])).to eq(['Text'])
      expect(result.removed).to eq('xml_comments' => 3)
      expect(described_class.survey(result.bytes)).to eq({})
    end

    it 'keeps a file with nothing to remove byte for byte' do
      bytes = OfficeFixtures.word('<w:p><w:r><w:t>Plain</w:t></w:r></w:p>',
                                  core: nil)
      result = tidy(bytes)
      expect(result.bytes).to eq(bytes)
      expect(result).not_to be_changed
    end

    it 'removes parts nothing uses, bytes outside the parts, and the ' \
       'signature the changes would break' do
      bytes = OfficeFixtures.word(
        '<w:p/>',
        core: nil,
        package_rels: [['rId7',
                        "#{OfficeFixtures::META.sub('metadata/', '')}" \
                        'digital-signature/origin',
                        '_xmlsignatures/origin.sigs']],
        parts: {
          'word/leftover.xml' => [nil, '<old>Jane Example</old>'],
          '_xmlsignatures/origin.sigs' => [nil, ''],
          '_xmlsignatures/_rels/origin.sigs.rels' => [nil, OfficeFixtures.rels(
            [['rId1', "#{OfficeFixtures::META.sub('metadata/', '')}" \
                      'digital-signature/signature', 'sig1.xml']]
          )],
          '_xmlsignatures/sig1.xml' => [nil, '<Signature/>']
        },
        between: 'Jane Example'
      )
      result = tidy(bytes)
      out = OfficeFixtures.parts(result.bytes)
      expect(out.keys).
        not_to include('word/leftover.xml', '_xmlsignatures/sig1.xml')
      expect(result.bytes).not_to include('Jane Example')
      expect(result.removed).to eq('unlisted_parts' => 1, 'signatures' => 1,
                                   'unlisted_bytes' => 12)
    end

    it 'rewrites a file whose only extra data is in zip extra fields' do
      bytes = OfficeFixtures.word('<w:p/>', core: nil)
      # A custom extra field on the first entry's local and central headers.
      field = [0xCAFE + 1, 22].pack('vv') + 'SYNTHETIC_PRIVATE_NOTE'.b
      with_extra = add_extra(bytes, field)
      expect(OfficePackage::Archive.new(with_extra).extra_bytes).to eq(52)
      result = tidy(with_extra)
      expect(result.bytes).not_to include('SYNTHETIC_PRIVATE_NOTE')
      expect(result.removed).to eq('unlisted_bytes' => 52)
      expect(OfficePackage::Archive.new(result.bytes).extra_bytes).to eq(0)
    end

    it 'writes the same bytes for the same file' do
      bytes = AttachmentFixtures.docx(paragraphs: ['Fleet'])
      expect(tidy(bytes).bytes).to eq(tidy(bytes).bytes)
    end
  end

  describe 'a workbook' do
    let(:note_vml) do
      '<xml xmlns:v="urn:schemas-microsoft-com:vml" ' \
        'xmlns:x="urn:schemas-microsoft-com:office:excel">' \
        '<v:shape><x:ClientData ObjectType="Note"><x:Row>0</x:Row>' \
        '</x:ClientData></v:shape>%s</xml>'
    end

    def commented(vml_extra = '')
      OfficeFixtures.workbook(
        sheets: { 'xl/worksheets/sheet1.xml' => OfficeFixtures.sheet_xml(
          [%w[Depot Vans]], extra: '<legacyDrawing r:id="rIdV"/>'
        ) },
        core: nil,
        sheet_rels: { 'xl/worksheets/sheet1.xml' => [
          ['rIdC', "#{r}comments", '../comments1.xml'],
          ['rIdV', "#{r}vmlDrawing", '../drawings/vmlDrawing1.vml'],
          ['rIdT', "#{OfficeFixtures::MS2017}threadedComment",
           '../threadedComments/threadedComment1.xml']
        ] },
        workbook_rels: [['rIdP', "#{OfficeFixtures::MS2017}person",
                         'persons/person.xml']],
        defaults: { 'vml' => "#{ct}vmlDrawing" },
        parts: {
          'xl/comments1.xml' => [
            "#{ct}spreadsheetml.comments+xml",
            "<comments #{OfficeFixtures::X}><commentList><comment ref=\"A1\">" \
            '<text><t>Ask Jane</t></text></comment></commentList></comments>'
          ],
          'xl/drawings/vmlDrawing1.vml' => [nil, format(note_vml, vml_extra)],
          'xl/threadedComments/threadedComment1.xml' =>
            ['application/vnd.ms-excel.threadedcomments+xml', '<t/>'],
          'xl/persons/person.xml' =>
            ['application/vnd.ms-excel.person+xml', '<personList/>']
        }
      )
    end

    it 'removes comments, their note shapes and their authors' do
      result = tidy(commented)
      out = OfficeFixtures.parts(result.bytes)
      expect(out.keys).not_to include(
        'xl/comments1.xml', 'xl/drawings/vmlDrawing1.vml',
        'xl/threadedComments/threadedComment1.xml', 'xl/persons/person.xml'
      )
      expect(out['xl/worksheets/sheet1.xml']).not_to include('legacyDrawing')
      expect(out['xl/worksheets/sheet1.xml']).to include('Depot')
      expect(result.removed).to eq('comments' => 1, 'author_lists' => 1)
    end

    it 'removes VML note shapes even when xmlns:v and xmlns:x are omitted' do
      raw_vml = '<xml><v:shape><v:textbox>Secret note</v:textbox>' \
                '<x:ClientData ObjectType="Note"/></v:shape></xml>'
      bytes = OfficeFixtures.workbook(
        core: nil,
        sheet_rels: {
          'xl/worksheets/sheet1.xml' => [
            ['rC1', "#{r}comments", '../comments1.xml'],
            ['rV1', "#{r}vmlDrawing", '../drawings/vmlDrawing1.vml']
          ]
        },
        parts: {
          'xl/comments1.xml' => [
            "#{ct}spreadsheetml.comments+xml",
            "#{OfficeFixtures::DECLARATION}<comments #{OfficeFixtures::X}>" \
            '<commentList><comment ref="A1"><text><t>Secret note</t></text>' \
            '</comment></commentList></comments>'
          ],
          'xl/drawings/vmlDrawing1.vml' => [
            'application/vnd.openxmlformats-officedocument.vmlDrawing',
            raw_vml
          ]
        }
      )
      result = tidy(bytes)
      out = OfficeFixtures.parts(result.bytes)
      expect(out.keys).not_to include('xl/drawings/vmlDrawing1.vml')
      expect(result.bytes).not_to include('Secret note'.b)
    end

    it 'keeps form controls in the note drawing' do
      checkbox = '<v:shape><x:ClientData ObjectType="Checkbox"/></v:shape>'
      result = tidy(commented(checkbox))
      out = OfficeFixtures.parts(result.bytes)
      expect(out['xl/drawings/vmlDrawing1.vml']).to include('Checkbox')
      expect(out['xl/drawings/vmlDrawing1.vml']).not_to include('Note')
      expect(out['xl/worksheets/sheet1.xml']).to include('legacyDrawing')
    end

    def pivoted(parts = {}, rels = [])
      OfficeFixtures.workbook(
        sheets: {
          'xl/worksheets/sheet1.xml' => OfficeFixtures.sheet_xml(
            [%w[Name Depot], ['Jane Example', 'North']]
          ),
          'xl/worksheets/sheet2.xml' => OfficeFixtures.sheet_xml(
            [%w[Depot Count], %w[North 1]],
            extra: '<sheetViews><sheetView><pivotSelection/></sheetView>' \
                   '</sheetViews>'
          )
        },
        core: nil,
        workbook_rels: [['rIdC', "#{r}pivotCacheDefinition",
                         'pivotCache/pivotCacheDefinition1.xml']] + rels,
        workbook_extra: '<pivotCaches><pivotCache cacheId="1" r:id="rIdC"/>' \
                        '</pivotCaches>',
        sheet_rels: { 'xl/worksheets/sheet2.xml' => [
          ['rIdT', "#{r}pivotTable", '../pivotTables/pivotTable1.xml']
        ] },
        parts: {
          'xl/pivotTables/pivotTable1.xml' =>
            ["#{ct}spreadsheetml.pivotTable+xml", '<pivotTableDefinition/>'],
          'xl/pivotTables/_rels/pivotTable1.xml.rels' =>
            [nil, OfficeFixtures.rels(
              [['rId1', "#{r}pivotCacheDefinition",
                '../pivotCache/pivotCacheDefinition1.xml']]
            )],
          'xl/pivotCache/pivotCacheDefinition1.xml' => [
            "#{ct}spreadsheetml.pivotCacheDefinition+xml",
            '<pivotCacheDefinition><cacheFields><cacheField name="Name">' \
            '<sharedItems><s v="Jane Example"/></sharedItems></cacheField>' \
            '</cacheFields></pivotCacheDefinition>'
          ],
          'xl/pivotCache/_rels/pivotCacheDefinition1.xml.rels' =>
            [nil, OfficeFixtures.rels([['rId1', "#{r}pivotCacheRecords",
                                        'pivotCacheRecords1.xml']])],
          'xl/pivotCache/pivotCacheRecords1.xml' =>
            ["#{ct}spreadsheetml.pivotCacheRecords+xml", '<pivotCacheRecords/>']
        }.merge(parts)
      )
    end

    it 'turns pivot tables into the values they show' do
      result = tidy(pivoted)
      out = OfficeFixtures.parts(result.bytes)
      expect(out.keys.grep(/pivot/i)).to be_empty
      expect(out['xl/workbook.xml']).not_to include('pivotCache')
      expect(out['xl/worksheets/sheet2.xml']).to include('North')
      expect(out['xl/worksheets/sheet2.xml']).not_to include('pivotSelection')
      expect(result.removed).to eq('pivot_tables' => 1)
    end

    it 'keeps pivot tables that a slicer depends on' do
      result = tidy(pivoted(
                      { 'xl/slicerCaches/slicerCache1.xml' =>
                          ['application/vnd.ms-excel.slicerCache+xml',
                           '<slicerCacheDefinition/>'] },
        [['rIdS', 'http://schemas.microsoft.com/office/2007/relationships/' \
                  'slicerCache', 'slicerCaches/slicerCache1.xml']]
                    ))
      expect(OfficeFixtures.parts(result.bytes).keys).
        to include('xl/pivotCache/pivotCacheDefinition1.xml')
      expect(result.kept).to eq('pivot_tables' => 1)
    end

    it 'removes the cached cells of linked workbooks and their folders' do
      link = "<externalLink #{OfficeFixtures::X}><externalBook r:id=\"rId1\">" \
             '<sheetNames><sheetName val="Staff"/></sheetNames><sheetDataSet>' \
             '<sheetData sheetId="0"><row r="1"><cell r="A1" t="str">' \
             '<v>Jane Example</v></cell></row></sheetData></sheetDataSet>' \
             '</externalBook></externalLink>'
      result = tidy(OfficeFixtures.workbook(
                      core: nil,
                      workbook_rels: [['rIdL', "#{r}externalLink",
                                       'externalLinks/externalLink1.xml']],
                      parts: {
                        'xl/externalLinks/externalLink1.xml' =>
                          ["#{ct}spreadsheetml.externalLink+xml", link],
                        'xl/externalLinks/_rels/externalLink1.xml.rels' =>
                          [nil, OfficeFixtures.rels(
                            [['rId1', "#{r}externalLinkPath",
                              # rubocop:disable Layout/LineLength -- a file URL
                              'file:///C:\\Users\\jexample\\Documents\\Staff.xlsx', 'External']]
                            # rubocop:enable Layout/LineLength
                          )]
                      }
                    ))
      out = OfficeFixtures.parts(result.bytes)
      expect(out['xl/externalLinks/externalLink1.xml']).not_to include('Jane')
      expect(out['xl/externalLinks/externalLink1.xml']).to include('Staff')
      expect(out['xl/externalLinks/_rels/externalLink1.xml.rels']).
        to include('Target="Staff.xlsx"')
      expect(result.removed).to eq('linked_workbook_caches' => 1)
    end
  end

  describe 'a presentation' do
    it 'removes old and new comments, their authors and the references ' \
       'to them' do
      slide = "<p:sld #{OfficeFixtures::P} " \
              'xmlns:p188="http://schemas.microsoft.com/office/powerpoint/' \
              '2018/8/main"><p:cSld><p:spTree/></p:cSld><p:extLst>' \
              '<p:ext uri="{6950BFC3-D8DA-4A85-94F7-54DA5524770B}">' \
              '<p188:commentRel r:id="rId3"/></p:ext></p:extLst></p:sld>'
      result = tidy(OfficeFixtures.deck(
                      slides: { 'ppt/slides/slide1.xml' => slide },
                      slide_rels: { 'ppt/slides/slide1.xml' => [
                        ['rId2', "#{r}comments", '../comments/comment1.xml'],
                        ['rId3', "#{OfficeFixtures::MS2018}comments",
                         '../comments/modernComment_100_1.xml']
                      ] },
                      deck_rels: [
                        ['rIdA', "#{r}commentAuthors", 'commentAuthors.xml'],
                        ['rIdB', "#{OfficeFixtures::MS2018}authors",
                         'authors.xml']
                      ],
                      parts: {
                        'ppt/comments/comment1.xml' => [
                          "#{ct}presentationml.comments+xml",
                          "<p:cmLst #{OfficeFixtures::P}>" \
                          '<p:cm authorId="0"><p:text>Jane says no</p:text>' \
                          '</p:cm></p:cmLst>'
                        ],
                        'ppt/comments/modernComment_100_1.xml' =>
                          ['application/vnd.ms-powerpoint.comments+xml',
                           '<p188:cmLst xmlns:p188="urn:p188">' \
                           '<p188:cm/></p188:cmLst>'],
                        'ppt/commentAuthors.xml' =>
                          ["#{ct}presentationml.commentAuthors+xml",
                           '<p:cmAuthorLst/>'],
                        'ppt/authors.xml' =>
                          ['application/vnd.ms-powerpoint.authors+xml',
                           '<authorLst/>']
                      }
                    ))
      out = OfficeFixtures.parts(result.bytes)
      expect(out.keys.grep(/comment|authors/i)).to be_empty
      expect(out['ppt/slides/slide1.xml']).
        not_to include('extLst', 'commentRel')
      expect(result.removed).to eq('comments' => 2, 'author_lists' => 2)
    end
  end

  it 'leaves none of the types it removes in the files other specs use' do
    fixtures = Pathname(__dir__).join('../../../spec/fixtures/files')
    {
      'lorem.docx' => File.binread(fixtures.join('lorem.docx')),
      'interesting.xlsx' => File.binread(fixtures.join('interesting.xlsx')),
      'interesting.pptx' => File.binread(fixtures.join('interesting.pptx')),
      'fixture.docx' => AttachmentFixtures.docx(paragraphs: ['Fleet'])
    }.each do |name, bytes|
      result = tidy(bytes)
      expect(described_class.survey(result.bytes)).to eq({}), name
    end
  end

  it 'refuses a file that is not Word, Excel or PowerPoint' do
    bytes = OfficeFixtures.package(
      { '[Content_Types].xml' => OfficeFixtures.content_types({}),
        '_rels/.rels' => OfficeFixtures.rels([]) }
    )
    expect { tidy(bytes) }.to raise_error(OfficePackage::Refused)
  end
end
