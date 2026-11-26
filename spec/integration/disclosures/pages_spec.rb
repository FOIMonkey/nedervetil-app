require 'spec_helper'

RSpec.describe 'Disclosures pages' do
  include ActiveJob::TestHelper
  include DisclosuresHelpers
  include_context 'with document OCR off'
  include_context 'with production error pages'

  let(:owner) { FactoryBot.create(:user, name: 'Rowan Requester') }
  let(:admin) { FactoryBot.create(:admin_user) }
  let(:other) { FactoryBot.create(:user) }
  let(:info_request) do
    FactoryBot.create(:info_request, user: owner, title: 'Pothole repairs 2024')
  end
  let(:letter) do
    AttachmentFixtures.pdf(
      pages: [
        {
          texts: [
            { x: 72,
              y: 760,
              text: 'Freedom of Information request: pothole repairs',
              size: 12 },
            { x: 72, y: 700, text: 'Repairs     Ward     Cost', size: 12 }
          ]
        }
      ]
    )
  end
  let(:message) do
    AttachmentFixtures.deliver(info_request,
                               [['response.pdf', 'application/pdf', letter]])
  end
  let(:attachment) do
    message.get_attachments_for_display.
      find { |a| a.filename == 'response.pdf' }
  end

  def published_document
    document = Disclosures::Creation.new(user: owner,
                                         attachment: attachment,
                                         kind: 'released_records').create!
    publish(document, by: admin)
    document.reload
  end

  it 'shows a published document of a private request to a visitor, never public-cacheable and with no cookie' do
    document = published_document
    document_request :get, "/documents/#{document.public_id}"
    expect(response).to have_http_status(:ok)
    expect(response.body).to include(document.title)
    expect(response.body).not_to include('Pothole repairs 2024')
    expect(response.headers['Cache-Control']).to eq('private, no-store')
    expect(response.headers['Set-Cookie']).to be_blank
    expect(response.body).not_to include('/rails/active_storage/')

    document_request :get, "/request/#{info_request.url_title}"
    expect(response).to have_http_status(:not_found)

    document_request :get, "/documents/#{document.public_id}/download"
    expect(response).to have_http_status(:ok)
    expect(response.headers['Content-Disposition']).to start_with('attachment')
    expect(response.headers['Content-Security-Policy']).to include('sandbox')

    document_request :get, "/documents/#{document.public_id}/pages/1"
    expect(response).to have_http_status(:ok)
    expect(response.media_type).to eq('image/png')
  end

  it 'finds a published document by the text OCR read from its clean copy, with no cookie' do
    skip 'Tesseract, pdftoppm or prlimit not installed' unless ocr_tools?
    Disclosures.ocr = true
    document = published_document
    document_request :get, '/documents', params: { q: 'potholes' }
    expect(response).to have_http_status(:ok)
    expect(response.body).to include(document.title, '<mark>')
    expect(response.headers['Set-Cookie']).to be_blank
  end

  it 'shows the requester the panel and their draft, and nobody else' do
    document = Disclosures::Creation.new(user: owner,
                                         attachment: attachment,
                                         kind: 'released_records').create!
    Disclosures::Suggester.new(message).run

    document_request :get, "/documents/#{document.public_id}"
    expect(response).to have_http_status(:not_found)

    sign_in(other)
    document_request :get, "/documents/#{document.public_id}/manage"
    expect(response).to have_http_status(:not_found)

    sign_in(owner)
    document_request :get, "/request/#{info_request.url_title}"
    expect(response).to have_http_status(:ok)
    expect(response.body).to include(document.title)
    document_request :get, "/documents/#{document.public_id}/manage"
    expect(response).to have_http_status(:ok)
    expect(response.body).to include('document-manage')
  end

  it 'answers 410 for a withdrawn document and 404 for an unknown one' do
    document = published_document
    Disclosures::Publication.new(document, user: owner).
      withdraw!(reason: 'Synthetic')
    document_request :get, "/documents/#{document.public_id}"
    expect(response).to have_http_status(:gone)
    expect(response.body).not_to include(document.title)
    document_request :get, '/documents/abcdefghijkl'
    expect(response).to have_http_status(:not_found)
  end

  it 'keeps text laid out in columns unwrapped, and sets letters as reading text' do
    table = Disclosures::Page.new(
      text: "Drone   Model   Year\nAP-01   A-200   2021\nAP-02   A-200   2021\n"
    )
    letter = Disclosures::Page.new(
      text: "Dear Rowan,\nThank you for your request.\nYours sincerely,\n"
    )
    expect([table.columnar?, letter.columnar?]).to eq([true, false])
  end

  it 'marks where a search hit is cut from its page' do
    hit = "one \u0002two\u0003 three"
    expect(Disclosures::Search.clipped(hit,
                                       'zero one two three',
                                       'one two three four')).
      to eq("… #{hit} …")
    expect(Disclosures::Search.clipped(hit, 'one two three', 'one two three')).
      to eq(hit)
  end

  it 'loads page rows without their search column, which search still reads' do
    document = published_document
    queries = []
    listener = ->(*, payload) { queries << payload[:sql] }
    ActiveSupport::Notifications.subscribed(listener, 'sql.active_record') do
      document_request :get, "/documents/#{document.public_id}"
    end
    expect(response).to have_http_status(:ok)
    page_rows = queries.grep(/FROM "disclosure_pages"/)
    expect(page_rows).to be_present
    expect(page_rows.join("\n")).
      not_to include('search_vector', '"disclosure_pages".*')
    document.pages.first.update!(text: 'Zebracorn depot')
    expect(Disclosures::Search.new(q: 'zebracorn').results).to eq([document])
  end
end
