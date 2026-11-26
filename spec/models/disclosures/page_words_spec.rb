require 'spec_helper'

RSpec.describe Disclosures::PageWords do
  include ActiveJob::TestHelper
  include DisclosuresHelpers
  include_context 'with document OCR off'

  let(:owner) { FactoryBot.create(:user) }
  let(:info_request) { FactoryBot.create(:info_request, user: owner) }
  let(:secret_line) { %w[Visible council records] }
  let(:letter) do
    AttachmentFixtures.letter_page(secret: secret_line.join(' '))
  end

  def document_of(*pages, **options)
    doc = delivered_document(info_request, 'records.pdf', 'application/pdf',
                             AttachmentFixtures.pdf(pages: pages), **options)
    Disclosures::Renderer.new(doc).run
    doc.reload
  end

  def words_on(document, number = 1)
    document.pages.find_by(number: number).words&.map&.fetch(:words)
  end

  def texts(words)
    words.map { |word| word[:text] }
  end

  def within?(outer, box)
    outer[0] <= box[0] && outer[1] <= box[1] &&
      outer[2] >= box[2] && outer[3] >= box[3]
  end

  describe 'the words kept when a version is made' do
    it 'are the PDF\'s own, in reading order, each in its place on the page' do
      words = words_on(document_of(letter))
      expect(texts(words)).
        to eq(%w[Response to your request Visible council records
                 Information Rights Team])
      expect(words.map { |word| word[:id] }).to eq((0...10).map(&:to_s))
      expect(words.map { |word| word[:line] }).
        to eq(%w[0 0 0 0 1 1 1 2 2 2])
      secret = words.select { |word| word[:line] == '1' }
      expect(secret).to all(
        satisfy do |word|
          within?(AttachmentFixtures.letter_secret_box, word[:box])
        end
      )
    end

    it 'are placed as the page is shown when the file turns it' do
      words = words_on(document_of(letter.merge(rotate: 90)))
      secret = words.select { |word| secret_line.include?(word[:text]) }
      expect(texts(secret)).to eq(secret_line)
      expect(secret).to all(
        satisfy do |word|
          within?(AttachmentFixtures.rotated_secret_box, word[:box])
        end
      )
    end

    it 'are placed within the crop box, which is what the page image shows' do
      whole = words_on(document_of(letter)).
        select { |word| word[:line] == '1' }
      cropped = words_on(
        FactoryBot.create(:info_request, user: owner).then do |request|
          doc = delivered_document(
            request, 'cropped.pdf', 'application/pdf',
            AttachmentFixtures.pdf(
              pages: [letter.merge(crop_box: [0, 421, 595, 842])]
            )
          )
          Disclosures::Renderer.new(doc).run
          doc.reload
        end
      ).select { |word| secret_line.include?(word[:text]) }
      # The top half of the page: the same places across, twice as far down.
      whole.zip(cropped).each do |before, after|
        expect(after[:box][0]).to be_within(0.001).of(before[:box][0])
        expect(after[:box][1]).to be_within(0.001).of(before[:box][1] * 2)
        expect(after[:box][3]).to be_within(0.001).of(before[:box][3] * 2)
      end
    end

    it 'keep a word that runs off the page within it' do
      page = letter
      page[:texts] << { x: 480, y: 400, size: 24, text: 'Overhangingword' }
      words = words_on(document_of(page))
      # pdftotext gives the letters that start on the page, and a box that
      # runs past its edge.
      word = words.find { |found| found[:text].start_with?('Overhang') }
      expect(word[:box][2]).to eq(1.0)
      expect(words.flat_map { |found| found[:box] }).to all(be_between(0, 1))
    end

    it 'follow the rows the page\'s text is read in, across a table\'s columns' do
      table = { texts: [
        { x: 72, y: 700, text: 'Name of the service provided', size: 12 },
        { x: 380, y: 700, text: 'Cost in pounds', size: 12 },
        { x: 72, y: 670, text: 'Street cleaning and gritting', size: 12 },
        { x: 380, y: 670, text: 'Twelve thousand', size: 12 }
      ] }
      document = document_of(table)
      words = words_on(document)
      expect(texts(words.select { |word| word[:line] == '0' })).
        to eq(%w[Name of the service provided Cost in pounds])
      expect(texts(words.select { |word| word[:line] == '1' })).
        to eq(%w[Street cleaning and gritting Twelve thousand])
      expect(document.pages.first.text.lines.map(&:split)).
        to eq(words.group_by { |word| word[:line] }.values.
                map { |row| texts(row) })
    end

    it 'leave out text that does not show: white text and text under a box' do
      canaries = { texts: [{ x: 72, y: 740, size: 24,
                             text: 'Visible public records of the council' },
                           { x: 72, y: 600, text: 'WHITEHIDDENCANARY',
                             colour: [1, 1, 1] },
                           { x: 72, y: 400, text: 'COVEREDCANARY' },
                           { x: 72, y: 300,
                             text: 'A second line that shows' }],
                   boxes: [{ x: 60, y: 390, w: 460, h: 40 }] }
      document = document_of(canaries)
      expect(texts(words_on(document)).join(' ')).to eq(
        'Visible public records of the council A second line that shows'
      )
      expect(described_class.sole.words.to_json).
        not_to include('WHITEHIDDENCANARY', 'COVEREDCANARY')
    end
  end

  describe 'a page of text that also has a picture on it' do
    before do
      allow(PDFRedactor::Survey).to receive(:pages).and_return(
        [{ 'number' => 1, 'visible' => 60, 'unmapped' => 0,
           'picture_share' => 0.4 },
         { 'number' => 2, 'visible' => 60, 'unmapped' => 0,
           'picture_share' => 0.0 }]
      )
    end

    it 'keeps its words, marked as not speaking for the picture' do
      document = document_of(letter, letter)
      first, second = document.pages.map(&:words)
      expect(texts(first.map[:words])).to include('Visible', 'council')
      expect(first.pictures).to be true
      expect(second.pictures).to be false
    end
  end

  describe 'a scan that carries a text layer of its own' do
    it 'keeps that layer\'s words, marked as not speaking for the picture' do
      document = delivered_document(info_request, 'scan.pdf',
                                    'application/pdf',
                                    DocumentFixtures.searchable_scan_pdf)
      Disclosures::Renderer.new(document).run
      page = document.reload.pages.first
      expect(page.text_source).to eq('pdftotext')
      expect(texts(page.words.map[:words])).
        to eq(%w[Zebrafinch Quillwort Marshwren Peregrine Hollyoak
                 Kestrelmoor])
      expect(page.words.pictures).to be true
    end
  end

  describe 'pages that keep none, and have boxes drawn by hand' do
    it 'a page with too little text to stand for it' do
      document = document_of(
        letter, { texts: [{ x: 72, y: 700, text: 'Short page.', size: 24 }] }
      )
      expect(words_on(document, 1)).to be_present
      expect(words_on(document, 2)).to be_nil
      expect(described_class.page_ids(document)).
        to eq(Set[document.pages.first.id])
    end

    it 'a page whose fonts do not map to letters, so its text can\'t be trusted' do
      allow(PDFRedactor::Survey).to receive(:pages).and_return(
        [{ 'number' => 1, 'visible' => 40, 'unmapped' => 30,
           'picture_share' => 0.0 },
         { 'number' => 2, 'visible' => 40, 'unmapped' => 30,
           'picture_share' => 0.4 },
         { 'number' => 3, 'visible' => 60, 'unmapped' => 0,
           'picture_share' => 0.0 }]
      )
      document = document_of(letter, letter, letter)
      expect(words_on(document, 1)).to be_nil
      expect(words_on(document, 2)).to be_nil
      expect(words_on(document, 3)).to be_present
    end

    it 'every page when the file could not be surveyed' do
      allow(PDFRedactor::Survey).to receive(:pages).
        and_raise(PDFRedactor::Error, 'synthetic')
      expect(words_on(document_of(letter))).to be_nil
      expect(described_class.count).to eq(0)
    end

    it 'a page that could not be measured, so which words show is not known' do
      allow(Disclosures::PDFText).to receive(:page_size).and_return([0, 0])
      document = document_of(letter)
      expect(document.pages.first.text).to include('Visible')
      expect(words_on(document)).to be_nil
    end

    it 'has no lines from PDFText for a page it could not measure' do
      word = { text: 'Word', x0: 10.0, y0: 10.0, x1: 40.0, y1: 20.0 }
      page = Disclosures::PDFText.visible(1, 0, 0, [[word]], {})
      expect(page).to have_attributes(text: 'Word', lines: nil)
    end

    it 'a Word file, though its pages are shown from a PDF of it' do
      document = delivered_document(
        info_request, 'letter.docx',
        'application/vnd.openxmlformats-officedocument.' \
        'wordprocessingml.document',
        AttachmentFixtures.docx(
          paragraphs: ['A letter with quite enough words in it to count ' \
                       'as a page of text for the checks.']
        )
      )
      Disclosures::Renderer.new(document).run
      expect(document.reload.format).to eq('document')
      expect(document.pages.first.text).to include('letter')
      expect(described_class.count).to eq(0)
    end

    it 'a page with more words than the editor takes' do
      stub_const('AttachmentManagement::WordMap::MAX_WORDS', 5)
      expect(words_on(document_of(letter))).to be_nil
    end

    it 'a file that is not a PDF' do
      document = delivered_document(info_request, 'notes.txt', 'text/plain',
                                    "Plain notes about parking permits.\n")
      Disclosures::Renderer.new(document).run
      expect(described_class.count).to eq(0)
    end
  end

  describe 'how long the words are kept' do
    let(:document) { document_of(letter) }

    before { expect(described_class.page_ids(document).size).to eq(1) }

    it 'go with the page, however the page is deleted' do
      expect { document.purge_public_pages! }.
        to change(described_class, :count).from(1).to(0)
    end

    it 'go with the document' do
      expect { document.destroy! }.
        to change(described_class, :count).from(1).to(0)
    end
  end
end
