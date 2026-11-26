# Office files for comparing what OfficePackage's readers give in different
# places, { name => bytes }: the fixtures, and invented files.
module OfficeReaderCorpus
  module_function

  def files
    fixtures = %w[lorem.docx interesting.xlsx sparse.xlsx interesting.pptx
                  example.zip lorem.doc].to_h do |name|
      [name, File.binread(Rails.root.join('spec/fixtures/files', name))]
    end
    fixtures.merge(made)
  end

  # Invented files for what the fixtures don't have: hidden content, number
  # formats, refusals, nested files, and blank names and properties.
  def made
    office = OfficeFixtures
    blank_core = OfficeFixtures::CORE.
                 sub('Jane Example</dc:creator>', " </dc:creator>").
                 sub('<cp:lastModifiedBy>Jane Example',
                     '<cp:lastModifiedBy> Bob ')
    {
      'changes.docx' => office.word(
        '<w:p><w:ins><w:r><w:t>a</w:t></w:r></w:ins>' \
        '<w:del><w:r><w:delText>b</w:delText></w:r></w:del>' \
        '<w:r><w:rPr><w:vanish/></w:rPr><w:t>h</w:t></w:r></w:p>',
        parts: {
          'word/comments.xml' => [
            "#{OfficeFixtures::CT}wordprocessingml.comments+xml",
            "<w:comments #{OfficeFixtures::W}><w:comment w:id=\"1\"><w:p>" \
            '<w:r><w:t>Note</w:t></w:r></w:p></w:comment></w:comments>'
          ],
          'word/embeddings/oleObject1.bin' => [nil, 'x' * 10]
        }
      ),
      'blank-core.docx' => office.word('<w:p><w:r><w:t>a</w:t></w:r></w:p>',
                                       core: blank_core),
      'hidden.xlsx' => DocumentFixtures.xlsx(
        sheets: [{ name: 'Shown', rows: [%w[a b c], %w[d e f], %w[g h i]],
                   hidden_rows: [2], hidden_columns: ['B'] },
                 { name: 'Gone', rows: [['x']], hidden: true },
                 { name: 'Deep', rows: [['y']], hidden: :very },
                 { name: " ", rows: [['z']], hidden_rows: [1] }],
        creator: 'Jane Example'
      ),
      'states.xlsx' => office.workbook(
        sheets: { 'xl/worksheets/sheet1.xml' => office.sheet_xml,
                  'xl/worksheets/sheet2.xml' =>
                    office.sheet_xml([%w[a], %w[b]], hidden_rows: [1]),
                  'xl/worksheets/sheet3.xml' => office.sheet_xml },
        states: { 2 => 'hidden', 3 => 'visible' },
        parts: { 'xl/comments1.xml' =>
                   [nil, '<comments><commentList><comment ref="A1"/>' \
                         '<comment ref="A2"/></commentList></comments>'] }
      ),
      'styled.xlsx' => DocumentFixtures.styled_xlsx(
        [[45_658.5, 1], [0.256, 2], [-1234.5, 3], ['text', 4], [1.5, 5],
         [12, 6], ['', 0], ['white', 7]],
        formats: ['yyyy-mm-dd hh:mm', '0.0%', '#,##0.00;[Red]-#,##0.00',
                  '"Pre "@', '# ?/?', '[<10]"small";"big"'],
        xfs: [[0, 0], [164, 0], [165, 0], [166, 0], [167, 0], [168, 0],
              [169, 0], [0, 1]]
      ),
      'conditional.xlsx' => office.workbook(
        sheets: { 'xl/worksheets/sheet1.xml' =>
                    office.sheet_xml(extra: '<conditionalFormatting ' \
                                            'sqref="A1"/>') }
      ),
      'many-sheets.xlsx' => DocumentFixtures.xlsx(
        sheets: (1..201).map { |n| { name: "S#{n}", rows: [['a']] } }
      ),
      'doctype.xlsx' => office.package(
        { '[Content_Types].xml' => office.content_types({}),
          'xl/workbook.xml' => '<!DOCTYPE x><workbook/>' }
      ),
      'broken.xlsx' => office.package(
        { '[Content_Types].xml' => office.content_types({}),
          'xl/workbook.xml' => '<workbook><sheets>' }
      ),
      'notes.pptx' => office.deck(
        slides: { 'ppt/slides/slide1.xml' => "<p:sld #{OfficeFixtures::P}/>" },
        parts: { 'ppt/notesSlides/notesSlide1.xml' => [nil, '<x/>'],
                 'ppt/comments/comment1.xml' => [nil, '<x/>'] },
        core: OfficeFixtures::CORE
      ),
      'nested.docx' => office.word(
        '<w:p><w:r><w:t>outer words</w:t></w:r></w:p>',
        parts: {
          'word/embeddings/inner.docx' => [
            nil, office.word('<w:p><w:r><w:t>inner words</w:t></w:r></w:p>')
          ],
          'word/embeddings/oleObject1.bin' => [
            nil, office.compound([['Contents', 'compound words']])
          ]
        }
      ),
      'not-a-zip.docx' => 'not a zip'
    }
  end
end
