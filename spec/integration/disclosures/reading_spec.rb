require 'spec_helper'

RSpec.describe 'Reading a document' do
  include ActiveJob::TestHelper
  include DisclosuresHelpers
  include_context 'with document OCR off'
  include_context 'with production error pages'

  let(:owner) do
    FactoryBot.create(:user, name: 'Rowan Requester', trusted: true)
  end
  let(:admin) { FactoryBot.create(:admin_user) }
  let(:northmoor) do
    FactoryBot.create(:public_body, name: 'Northmoor County Council')
  end
  let(:westfold) do
    FactoryBot.create(:public_body, name: 'Westfold Borough Council')
  end

  def request_to(body, title: 'Pothole repairs and contractors')
    FactoryBot.create(
      :info_request, user: owner, public_body: body, title: title
    )
  end

  def document_from(request, name, type, bytes, kind: 'released_records', title: nil, document_date: nil)
    delivered_document(request, name, type, bytes, by: owner, kind: kind).
      tap do |document|
        document.update!({ title: title, document_date: document_date }.compact)
      end
  end

  def letter(request, **options)
    pages = [AttachmentFixtures.letter_page(secret: 'Contractors are withheld'),
             AttachmentFixtures.letter_page(secret: 'Zebracorn depot capacity')]
    document_from(request,
                  'letter.pdf',
                  'application/pdf',
                  AttachmentFixtures.pdf(pages: pages),
                  kind: 'decision_letter',
                  **options)
  end

  def text_records(request, **options)
    document_from(
      request, 'records.txt', 'text/plain', "Fleet records\n", **options
    )
  end

  def html
    Nokogiri::HTML(response.body)
  end

  describe Disclosures::Reader do
    it 'runs wrapped lines on into paragraphs, keeps short lines apart, and drops OCR’s stray blank lines' do
      text = "Northmoor County Council\n\nOur ref: FOI-2041\n" \
             "Date: 12 October 2026\n\nThank you for your request for " \
             "information. We have dealt with your request\n" \
             "under the Freedom of Information Act 2000.\n\n" \
             "Please write to us within 40 working days of the date of this " \
             "letter, or to\n\nthe Information Commissioner.\n\n" \
             "Yours sincerely,\n"
      expect(described_class.paragraphs(text)).
        to eq([['Northmoor County Council'],
               ['Our ref: FOI-2041', 'Date: 12 October 2026'],
               ['Thank you for your request for information. We have dealt ' \
                'with your request under the Freedom of Information Act 2000.'],
               ['Please write to us within 40 working days of the date of ' \
                'this letter, or to the Information Commissioner.'],
               ['Yours sincerely,']])
    end

    it 'runs a long run-on page into one paragraph in time that grows with its length, not its square' do
      lines = Array.new(20_000) do |index|
        "repairs to the carriageway were made in ward #{index} by the " \
        "contractor"
      end
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      paragraphs = described_class.paragraphs(lines.join("\n"))
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
      expect(paragraphs).to eq([[lines.join(' ')]])
      expect(elapsed).to be < 0.5
    end

    it 'finds words separately and a quoted phrase whole, leaving out search operators' do
      expect(described_class.terms('Pothole  contractors')).
        to eq(%w[Pothole contractors])
      expect(described_class.terms('"section 43"')).to eq(['section 43'])
      expect(described_class.terms('potholes -roads or a "ward')).
        to eq(%w[potholes ward])
      expect(described_class.terms('')).to eq([])
    end

    it 'marks the find in escaped text, and [redacted] as a mark of its own' do
      view = ActionView::Base.empty.extend(Disclosures::DocumentsHelper)
      pattern = described_class.new([], find: 'zebra').pattern
      expect(view.document_text_line('a <b> [redacted] Zebra zebra', pattern)).
        to eq('a &lt;b&gt; <span class="document-redacted">[redacted]</span> ' \
              '<mark>Zebra</mark> <mark>zebra</mark>')
      expect(view.document_text_line('<i>', nil)).to eq('&lt;i&gt;')
    end
  end

  describe 'a document’s page' do
    let!(:document) do
      publish(letter(request_to(northmoor),
                     title: 'Decision letter: pothole repairs'), by: admin)
    end

    it 'puts the answer first, then its facts and pages, with the script that switches the views' do
      get "/documents/#{document.public_id}"
      expect(response).to have_http_status(:ok)
      expect(html.at_css('title').text).to include(
        'Decision letter: pothole repairs · Northmoor County Council'
      )
      expect(html.css('.document-band__page').map { |img| img['src'] }).
        to eq(["/documents/#{document.public_id}/pages/2",
               "/documents/#{document.public_id}/pages/1"])
      expect(html.at_css('.document-band__read').text).to eq('Read the 2 pages')
      byline = html.at_css('.document-band__byline').text.squish
      expect(byline).to start_with('Northmoor County Council')
      expect(byline).to end_with('Decision letter')
      expect(html.at_css('.document-ledger')).to be_nil
      expect(html.at_css('#document-pages-view')['hidden']).to be_nil
      expect(html.at_css('#document-text-view')['hidden']).not_to be_nil
      expect(html.css('.document-thumbs a').map { |link| link['href'] }).
        to eq(%w[#page-1 #page-2])
      expect(html.at_css('.document-download').text.squish).
        to start_with('Download PDF')
      expect(html.at_css('script[type="importmap"]')).to be_present
      expect(html.at_css('[data-controller="document-views"]')).to be_present
      expect(response.headers['X-Robots-Tag']).to be_nil
      expect(response.body).not_to include('Pothole repairs and contractors',
                                           'Rowan Requester',
                                           '/request/')
    end

    it 'shows the Text view on request, and finds words in it without the page being indexed' do
      get "/documents/#{document.public_id}", params: { view: 'text' }
      expect(html.at_css('#document-pages-view')['hidden']).not_to be_nil
      expect(html.at_css('.document-views__link[aria-current]').text).
        to eq('Text')
      expect(html.at_css('#text-2').text).to include('Zebracorn depot capacity')
      expect(response.headers['X-Robots-Tag']).to eq('noindex, nofollow')

      get "/documents/#{document.public_id}",
          params: { find: 'zebracorn contractors' }
      expect(html.at_css('#document-text-view')['hidden']).to be_nil
      expect(html.css('#document-text-view mark').map(&:text)).
        to eq(%w[Contractors Zebracorn])
      expect(html.at_css('.document-find__count').text.squish).
        to eq('2 matches · p. 1, 2')
      expect(html.at_css('#text-1 #document-find-first')).to be_present

      get "/documents/#{document.public_id}",
          params: { find: 'quokka', view: 'pages' }
      expect(html.at_css('#document-pages-view')['hidden']).to be_nil
      expect(html.at_css('.document-find__count').text.squish).
        to eq('No matches')
    end

    it 'lists more published documents from the same authority, never a draft or another authority’s' do
      sheet = publish(text_records(request_to(northmoor),
                                   title: 'Repairs by ward'), by: admin)
      text_records(request_to(northmoor), title: 'Draft about gritting')
      publish(text_records(request_to(westfold), title: 'Westfold fleet'),
              by: admin)

      get "/documents/#{document.public_id}"
      cards = html.css('.document-more .document-card__title')
      expect(cards.map { |card| [card.text, card['href']] }).
        to eq([['Repairs by ward', "/documents/#{sheet.public_id}"]])
      expect(html.at_css('.document-card--all a').text).
        to eq('All documents from Northmoor County Council')
      expect(response.body).
        not_to include('Draft about gritting', 'Westfold fleet')
    end
  end
end
