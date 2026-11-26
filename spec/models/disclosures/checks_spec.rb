require 'spec_helper'

RSpec.describe Disclosures::Checks do
  describe '.partial' do
    def document(format: 'pdf', notes: nil, pages: [])
      Disclosures::Document.new(format: format, render_notes: notes).
        tap do |document|
          pages.each { |page| document.pages.build(page) }
        end
    end

    def image_page(number)
      { number: number, label: "Page #{number}", kind: 'image' }
    end

    def sheet(number, label, rows:, columns:, truncated: true)
      { number: number, label: label, kind: 'sheet', rows: rows,
        columns: columns, truncated: truncated }
    end

    def hit(page, label, anchor, what)
      described_class::Hit.new(page: page, label: label, anchor: anchor,
                               what: what)
    end

    it 'lists each kind of note in turn' do
      version = document(
        format: 'xlsx',
        notes: { 'pages_not_shown' => 7,
                 'ocr_skipped' => [4],
                 'unread_flagged' => [{ 'page' => 5,
                                        'reasons' => ['pictures'] }],
                 'unread_pages' => [7, 6],
                 'hiding_styles' => true,
                 'no_preview' => 'too_large' },
        pages: [sheet(1, 'Budget', rows: 2_500, columns: 3),
                sheet(2, 'Staff', rows: 100, columns: 70),
                sheet(3, 'Notes', rows: 10, columns: 2, truncated: false),
                image_page(4), image_page(5), image_page(6), image_page(7)]
      )

      expect(described_class.partial(version)).to eq(
        [hit(1, 'Sheet “Budget”', 'sheet-1',
             'rows 501–2,500 aren’t shown here'),
         hit(2, 'Sheet “Staff”', 'sheet-2',
             'only part of it is checked here (it has 100 rows and 70 ' \
             'columns)'),
         hit(7, 'Page 7', 'page-7',
             '7 more pages after it aren’t shown or checked here'),
         hit(4, 'Page 4', 'page-4',
             'not read (past the limit of pages read by OCR), so not ' \
             'checked here'),
         hit(5, 'Page 5', 'page-5',
             'its pictures couldn’t be read, so what they show isn’t ' \
             'checked here'),
         hit(6, 'Pages 6–7', 'page-6',
             'its text couldn’t be read from the scan, so it isn’t shown ' \
             'or checked here'),
         hit(nil, 'The file', 'checks-title',
             'has styles that can hide text, which this site can’t ' \
             'follow, so the text here may include words the page ' \
             'doesn’t show'),
         hit(nil, 'The file', 'checks-title',
             'couldn’t be shown or checked here')]
      )
    end

    it 'lists nothing for a document with no notes and no pages' do
      expect(described_class.partial(document)).to eq([])
    end

    it 'calls a CSV file’s cut-off sheet the file' do
      version = document(format: 'csv',
                         pages: [sheet(1, 'data', rows: 3_000, columns: 4)])

      expect(described_class.partial(version)).to eq(
        [hit(1, 'The file', 'sheet-1', 'rows 501–3,000 aren’t shown here')]
      )
    end

    it 'puts the pages past the limit on the last page, by the count given' do
      version = document(notes: { 'pages_not_shown' => '3' },
                         pages: [image_page(1), image_page(2)])

      expect(described_class.partial(version)).to eq(
        [hit(2, 'Page 2', 'page-2',
             '3 more pages after it aren’t shown or checked here')]
      )
    end

    it 'leaves out pages past the limit when there are none, or no pages' do
      expect(described_class.partial(
               document(notes: { 'pages_not_shown' => 0 },
                        pages: [image_page(1)])
             )).to eq([])
      expect(described_class.partial(
               document(notes: { 'pages_not_shown' => 4 })
             )).to eq([])
    end

    it 'skips a note about a page the document doesn’t have' do
      version = document(
        notes: { 'ocr_skipped' => [9],
                 'unread_flagged' => [{ 'page' => 9,
                                        'reasons' => ['glyphs'] }],
                 'unread_pages' => [9, 1] },
        pages: [image_page(1), image_page(2)]
      )

      expect(described_class.partial(version)).to eq(
        [hit(1, 'Pages 1, 9', 'page-1',
             'its text couldn’t be read from the scan, so it isn’t shown ' \
             'or checked here')]
      )
    end

    it 'leaves out the unread pages when the first isn’t in the document' do
      version = document(notes: { 'unread_pages' => [9, 10] },
                         pages: [image_page(10)])

      expect(described_class.partial(version)).to eq([])
    end

    it 'says why each flagged page couldn’t be read' do
      version = document(
        notes: { 'unread_flagged' => [
          { 'page' => 1, 'reasons' => ['glyphs'] },
          { 'page' => 2, 'reasons' => %w[pictures glyphs] }
        ] },
        pages: [image_page(1), image_page(2)]
      )

      expect(described_class.partial(version)).to eq(
        [hit(1, 'Page 1', 'page-1',
             'some of its text doesn’t map to letters and couldn’t be ' \
             'read, so it isn’t checked here'),
         hit(2, 'Page 2', 'page-2',
             'it couldn’t be read as it shows, so it isn’t fully checked ' \
             'here')]
      )
    end

    it 'names one unread page by its own label' do
      version = document(notes: { 'unread_pages' => [2] },
                         pages: [image_page(1), image_page(2)])

      expect(described_class.partial(version)).to eq(
        [hit(2, 'Page 2', 'page-2',
             'its text couldn’t be read from the scan, so it isn’t shown ' \
             'or checked here')]
      )
    end

    it 'ignores hiding styles and no preview when they are not set' do
      version = document(notes: { 'hiding_styles' => false,
                                  'no_preview' => '' })

      expect(described_class.partial(version)).to eq([])
    end
  end
end
