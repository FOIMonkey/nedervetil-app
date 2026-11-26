require 'spec_helper'

# send_file must send the same bytes and headers as send_data, except for the
# weak ETag that Rack::ETag adds to send_data.
RSpec.describe 'Disclosures file sending' do
  include ActiveJob::TestHelper
  include DisclosuresHelpers
  include_context 'with document OCR off'

  let(:owner) { FactoryBot.create(:user, name: 'Rowan Requester') }
  let(:admin) { FactoryBot.create(:admin_user) }
  let(:info_request) do
    FactoryBot.create(:info_request, user: owner, title: 'Gritting routes 2024')
  end
  let(:letter) do
    AttachmentFixtures.pdf(
      pages: [AttachmentFixtures.letter_page(secret: 'Salt by ward'),
              AttachmentFixtures.letter_page(secret: 'Salt by month')]
    )
  end

  def published_document
    message = AttachmentFixtures.deliver(
      info_request, [['response.pdf', 'application/pdf', letter]]
    )
    attachment = message.get_attachments_for_display.
      find { |a| a.filename == 'response.pdf' }
    document = Disclosures::Creation.new(user: owner,
                                         attachment: attachment,
                                         kind: 'released_records').create!
    publish(document.reload, by: admin)
    document.reload.tap { |published| expect(published).to be_listed }
  end

  # Header names are lower case in the plain Hash that #to_h gives.
  def volatile
    %w[etag x-request-id x-runtime set-cookie]
  end

  def sent(method, path)
    send(method, path)
    headers = response.headers.to_h.except(*volatile)
    headers['content-security-policy'] = headers['content-security-policy'].
      to_s.sub(/'nonce-[^']+'/, "'nonce'")
    { status: response.status,
      body: response.body.b,
      etag: response.headers['ETag'],
      headers: headers }
  end

  # No local path, so the file is read whole and sent with send_data.
  def read_whole(method, path)
    allow(Disclosures::Blobs).to receive(:local_path).and_return(nil)
    sent(method, path)
  ensure
    allow(Disclosures::Blobs).to receive(:local_path).and_call_original
  end

  it 'streams the published file with the same bytes and headers, and HEAD reads nothing' do
    document = published_document
    path = "/documents/#{document.public_id}/download"

    before = read_whole(:get, path)
    expect(before[:etag]).to be_present
    after = sent(:get, path)
    expect(after.except(:etag)).to eq(before.except(:etag))
    expect(after[:etag]).to be_nil
    expect(after[:body]).to eq(document.bytes)
    expect(after[:headers]).
      to include('content-disposition' => a_string_starting_with('attachment;'),
                 'content-security-policy' => "default-src 'none'; sandbox",
                 'cache-control' => 'private, no-store')

    expect_any_instance_of(ActiveStorage::Blob).not_to receive(:download)
    head path
    expect(response).to have_http_status(:ok)
    expect(response.body).to be_empty
    expect(response.headers.to_h.except(*volatile, 'content-length')).
      to eq(after[:headers].except('content-length'))
  end

  it 'serves nothing once withdrawn' do
    document = published_document
    path = "/documents/#{document.public_id}/download"
    Disclosures::Publication.new(document, user: admin).
      withdraw!(reason: 'Synthetic withdrawal')
    get path
    expect(response).to have_http_status(:not_found)
  end

  it 'streams page images and thumbnails inline, with no file name' do
    document = published_document
    page = document.pages.find_by!(number: 1)
    expect([page.image, document.thumbnail].map(&:attached?)).
      to eq([true, true])

    {
      "/documents/#{document.public_id}/pages/1" => page.image,
      "/documents/#{document.public_id}/thumbnail" => document.thumbnail
    }.each do |path, image|
      before = read_whole(:get, path)
      after = sent(:get, path)
      expect(after.except(:etag)).to eq(before.except(:etag))
      expect([after[:status], after[:etag], after[:body] == image.download]).
        to eq([200, nil, true])
      expect(after[:headers]).to include('content-type' => 'image/png',
                                         'content-disposition' => 'inline')
    end
  end
end
