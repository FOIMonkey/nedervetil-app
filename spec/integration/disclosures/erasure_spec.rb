require 'spec_helper'

RSpec.describe 'Disclosures erasure' do
  include ActiveJob::TestHelper
  include DisclosuresHelpers
  include_context 'with document OCR off'
  include_context 'with production error pages'

  let(:owner) { FactoryBot.create(:user, name: 'Synthetic Requester') }
  let(:admin) { FactoryBot.create(:admin_user) }
  let(:info_request) do
    FactoryBot.create(:info_request,
                      user: owner,
                      title: 'Synthetic ward figures')
  end

  def make_document
    bytes = AttachmentFixtures.pdf(
      pages: [AttachmentFixtures.letter_page(secret: 'North: 12')]
    )
    document = delivered_document(
      info_request, 'figures.pdf', 'application/pdf', bytes, by: owner
    )
    publish(document, by: admin)
    document.reload
  end

  def erase(document)
    sign_in(admin)
    document_request :post, "/documents/#{document.public_id}/erase",
                     params: { confirm: '1' }
    expect(response).to redirect_to("/documents/#{document.public_id}/manage")
  end

  it 'tells its requester an erased document is erased and purges public pages' do
    document = make_document
    page_blobs = document.pages.filter_map { |page| page.image.blob }
    thumb_blob = document.thumbnail.blob
    expect(page_blobs).to be_present
    expect(thumb_blob).to be_present

    erase(document)

    document.reload
    expect(document).to be_erased
    expect(document).not_to be_listed
    expect(document.pages).to be_empty
    expect(document.thumbnail).not_to be_attached
    expect(page_blobs.map { |b| b.service.exist?(b.key) }).to all(be false)
    expect(thumb_blob.service.exist?(thumb_blob.key)).to be false
    expect(document.foi_attachment.reload.prominence).to eq('requester_only')
    expect(document.events.where(action: 'erased').count).to eq(1)

    sign_in(owner)
    document_request :get, "/documents/#{document.public_id}/manage"
    expect(response).to have_http_status(:ok)
    expect(response.body).to include('It has been erased.')
    expect(Disclosures::RequesterPublication.problems(document).map(&:text)).
      to eq(['It has been erased.'])

    document_request :get, "/documents/#{document.public_id}/download"
    expect(response).to have_http_status(:not_found)
  end

  it 'purges the stored attachment file when the document is detached from its request' do
    document = make_document
    attachment = document.foi_attachment
    file_blob = attachment.file.blob
    Disclosures::RequestDeletion.new(info_request, owner).delete!
    expect(attachment.reload.incoming_message_id).to be_nil

    erase(document)

    expect(document.reload).to be_erased
    expect(attachment.reload).to be_erased
    expect(attachment.file).not_to be_attached
    expect(file_blob.service.exist?(file_blob.key)).to be false
  end
end
