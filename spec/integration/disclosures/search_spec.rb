require 'spec_helper'

RSpec.describe 'Disclosures search' do
  include ActiveJob::TestHelper
  include DisclosuresHelpers
  include_context 'with document OCR off'
  include_context 'with production error pages'

  let(:owner) do
    FactoryBot.create(:user,
                      name: 'Rowan Requester',
                      trusted: true)
  end
  let(:admin) { FactoryBot.create(:admin_user) }
  let(:info_request) do
    FactoryBot.create(:info_request, user: owner, title: 'Gritting routes 2024')
  end

  def document_from(name, type, bytes, kind: 'released_records', request: info_request)
    delivered_document(request, name, type, bytes, kind: kind)
  end

  def text_document(text, **options)
    document_from('records.txt', 'text/plain', text, **options)
  end

  def found(query, **filters)
    Disclosures::Search.new(q: query, **filters).results
  end

  it 'finds only published documents, by title and by the text of their pages' do
    published = text_document(
      "Gritting routes for the winter: Zebracorn depot\n"
    )
    publish(published, by: admin)
    published.update!(title: 'Winter gritting routes by depot')

    draft = text_document("Quokkaword appears only in a draft\n")
    draft.update!(title: 'Hedgehogtitle draft')

    withdrawn = text_document(
      "Wombatword appears only in a withdrawn document\n"
    )
    publish(withdrawn, by: admin)
    Disclosures::Publication.new(withdrawn, user: owner).
      withdraw!(reason: 'Synthetic check')

    expect(found('Zebracorn')).to eq([published])
    expect(found('gritting')).to eq([published])
    expect(found('Quokkaword')).to be_empty
    expect(found('Hedgehogtitle')).to be_empty
    expect(found('Wombatword')).to be_empty
    expect(Disclosures::Search.new({}).total).to eq(1)
  end

  it 'escapes snippets, and text in a file can’t make its own highlight' do
    # ts_headline drops whole tags itself; a bare "<" and "&" reach the snippet.
    document = text_document("Zebracorn depot 5 < 6 & \"quoted\" " \
                             "<script>alert('Zebracorn')</script> " \
                             "\u0002Fakemark\u0003 Zebracorn\n")
    publish(document, by: admin)
    expect(document.pages.first.text).
      not_to include("\u0002", "\u0003")

    snippets = Disclosures::Search.new(q: 'Zebracorn').
      hits[document.id].map(&:snippet)
    expect(snippets).to all(be_html_safe)
    expect(snippets.join).
      to include('<mark>Zebracorn</mark> depot 5 &lt; 6 &amp; &quot;quoted')
    expect(snippets.join).not_to include('<script', '<mark>Fakemark', '< 6')

    get '/documents', params: { q: 'Zebracorn' }
    expect(response).to have_http_status(:ok)
    expect(response.headers['Cache-Control']).to eq('private, no-store')
    expect(response.headers['Set-Cookie']).to be_blank
    expect(response.body).to include('<mark>Zebracorn</mark>')
    expect(response.body).
      not_to include("<script>alert('Zebracorn')", '<mark>Fakemark')
  end

  it 'gives each hit its page, and links to that page of the document' do
    pages = [AttachmentFixtures.letter_page(secret: 'Salt deliveries by month'),
             AttachmentFixtures.letter_page(secret: 'Zebracorn depot capacity')]
    document = document_from('salt.pdf',
                             'application/pdf',
                             AttachmentFixtures.pdf(pages: pages))
    publish(document, by: admin)

    hits = Disclosures::Search.new(q: 'Zebracorn').
      hits[document.id]
    expect(hits.map { |hit| [hit.number, hit.label, hit.anchor] }).
      to eq([[2, 'Page 2', 'page-2']])

    get '/documents', params: { q: 'Zebracorn' }
    expect(response.body).to include(
      %(href="/documents/#{document.public_id}?find=Zebracorn#text-2")
    )
    get "/documents/#{document.public_id}"
    expect(Nokogiri::HTML(response.body).at_css('#page-2')).to be_present
    get "/documents/#{document.public_id}", params: { find: 'Zebracorn' }
    html = Nokogiri::HTML(response.body)
    expect(html.at_css('#document-text-view')['hidden']).to be_nil
    expect(html.at_css('#document-pages-view')['hidden']).not_to be_nil
    expect(html.css('#text-2 mark').map(&:text)).to eq(['Zebracorn'])
    expect(html.at_css('.document-find__count').text.squish).
      to eq('1 match · p. 2')
  end

  it 'counts and filters by type, format and year over published documents only' do
    letter = text_document("We do not hold the information about Zebracorn.\n",
                           kind: 'decision_letter')
    letter.update!(document_date: Date.new(2024, 5, 1))
    publish(letter, by: admin)
    records = document_from(
      'salt.pdf',
      'application/pdf',
      AttachmentFixtures.pdf(
        pages: [AttachmentFixtures.letter_page(secret: 'Zebracorn depot')]
      )
    )
    publish(records, by: admin)
    text_document("A draft decision letter about Zebracorn.\n",
                  kind: 'decision_letter')

    facets = Disclosures::Search.new({}).facets
    counted = ->(key) do
      facets.fetch(key).to_h { |value, _label, count| [value.to_s, count] }
    end
    expect(counted.call(:kind)).
      to eq('decision_letter' => 1, 'released_records' => 1)
    expect(counted.call(:file_type)).to eq('text' => 1, 'pdf' => 1)
    expect(counted.call(:year)).
      to eq('2024' => 1, records.released_on.year.to_s => 1)

    expect(found('Zebracorn', kind: 'decision_letter')).to eq([letter])
    expect(found('Zebracorn', kind: 'released_records')).to eq([records])
    expect(found('Zebracorn', file_type: 'pdf')).to eq([records])
    expect(found('Zebracorn', file_type: 'text')).to eq([letter])
    expect(found('Zebracorn', year: '2024')).to eq([letter])
    expect(Disclosures::Search.new(kind: 'decision_letter').facets[:file_type].
             to_h { |value, _, count| [value, count] }).to eq('text' => 1)
  end

  it 'lists a round-robin batch’s documents together, as one entry' do
    batch = FactoryBot.create(:info_request_batch,
                              user: owner,
                              title: 'Salt stores 2025')
    documents = Array.new(2) do |index|
      child = FactoryBot.create(:info_request,
                                user: owner,
                                title: 'Salt stores 2025',
                                info_request_batch: batch)
      publish(text_document("Salt store #{index}: Zebracorn depot\n",
                            request: child), by: admin)
    end
    alone = publish(text_document("Zebracorn depot, a request of its own\n"),
                    by: admin)
    search = Disclosures::Search.new(q: 'Zebracorn')
    expect(search.total).to eq(3)
    expect(search.groups.size).to eq(3)
    expect(search.groups.any?(&:batch?)).to be(false)
    expect(search.results).to match_array(documents + [alone])
    get '/documents', params: { q: 'Zebracorn' }
    expect(response).to have_http_status(:ok)
    expect(Nokogiri::HTML(response.body).css('.document-group')).to be_empty
    expect(response.body).not_to include(batch.title)
  end

  it 'filters by file type through the page, and survives an absurd page number' do
    records = publish(text_document("Zebracorn depot ledger\n"), by: admin)

    get '/documents', params: { q: 'Zebracorn', file_type: 'text' }
    expect(response).to have_http_status(:ok)
    expect(Nokogiri::HTML(response.body).css('.document-result').size).to eq(1)
    expect(response.body).to include(records.title)

    get '/documents', params: { q: 'Zebracorn', file_type: 'pdf' }
    expect(response).to have_http_status(:ok)
    expect(Nokogiri::HTML(response.body).css('.document-result')).to be_empty

    get '/documents', params: { page: '99999999999999999999' }
    expect(response).to have_http_status(:ok)
  end

  it 'fails closed: a source hidden without any hook running takes the document out of search and off its page' do
    document = publish(text_document("Zebracorn depot salt store\n"), by: admin)
    expect(found('Zebracorn')).to eq([document])

    FoiAttachment.find(document.foi_attachment_id).
      update_column(:prominence, 'hidden')
    expect(document.reload.state).to eq('published')
    expect(document).not_to be_listed
    expect(found('Zebracorn')).to be_empty
    expect(Disclosures::Search.new({}).total).to eq(0)

    get "/documents/#{document.public_id}"
    expect(response).to have_http_status(:gone)
    expect(response.body).not_to include('Zebracorn', document.title)
    get "/documents/#{document.public_id}/download"
    expect(response).to have_http_status(:not_found)
  end
end
