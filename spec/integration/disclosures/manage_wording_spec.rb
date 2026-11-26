require 'spec_helper'

# What the requester's pages say matches the document's state.
RSpec.describe 'What the requester is told about a document' do
  include ActiveJob::TestHelper
  include DisclosuresHelpers
  include_context 'with document OCR off'

  around do |example|
    with_setting(Disclosures, :requester_editing, true) { example.run }
  end

  let(:owner) { FactoryBot.create(:user, name: 'Rowan Requester') }
  let(:admin) { FactoryBot.create(:admin_user) }
  let(:info_request) { FactoryBot.create(:info_request, user: owner) }

  def published_document
    document = delivered_document(info_request, 'repairs.txt', 'text/plain',
                                  "Repairs: 12\nWard: North Lane\n")
    publish(document, by: admin)
  end

  it 'calls a public document public, and says only an admin can put it back up' do
    document = published_document
    sign_in(owner)
    get "/documents/#{document.public_id}/manage"

    expect(response.body).to include('Public: anyone can read it.')
    expect(response.body).not_to include('Private: only you')
    expect(response.body).to include('Take this document down')
    expect(response.body).
      to include('Withdraw (only an admin can share it again)')
    expect(response.body).to include('Take down and edit again')
    expect(response.body).
      to include('It stops being public at once. Only an admin can share ' \
                 'it again.')
  end

  it 'counts a document submitted for admin review as waiting for admin review' do
    document = delivered_document(info_request, 'repairs.txt', 'text/plain',
                                  "Repairs: 12\nWard: North Lane\n")
    Disclosures::ReviewSubmission.submit!(document, user: owner)
    reply = Disclosures::PublishedReply.new(
      instance_double(Disclosures::ReplyDocuments, all: [document.reload])
    )

    expect(reply.listed).to be_empty
    expect(reply.waiting).to eq([document])
    expect(reply.title).to eq('Waiting for admin review')
  end

  it 'links signed-in users to Your documents from the catalogue index' do
    get disclosure_documents_path
    expect(response).to have_http_status(:ok)
    expect(response.body).not_to include(disclosure_your_documents_path)

    sign_in(owner)
    get disclosure_documents_path
    expect(response).to have_http_status(:ok)
    expect(response.body).to include(disclosure_your_documents_path)
    expect(response.body).to include('Your documents')
  end

  it 'explains draft deletion accurately without promising file rollback' do
    document = delivered_document(info_request, 'repairs.txt', 'text/plain',
                                  "Repairs: 12\n")
    sign_in(owner)
    get "/documents/#{document.public_id}/manage"

    expect(response.body).
      to include('any redactions already saved to the file stay in place')
    expect(response.body).not_to include('file in the thread is not changed')
  end

  it 'avoids saying nothing looks shareable when a reply already has shared files' do
    message = AttachmentFixtures.deliver(
      info_request,
      [['decision.pdf', 'application/pdf', DocumentFixtures.text_pdf(
        title: 'Decision', paragraphs: ['Granted.']
      )]],
      text: 'See attached.'
    )
    suggest_documents
    pdf_part = message.foi_attachments.find { _1.filename == 'decision.pdf' }
    doc = document_from_attachment(pdf_part, by: owner, kind: 'decision_letter')
    publish(doc, by: owner)

    sign_in(owner)
    get publish_reply_path(url_title: info_request.url_title,
                           message_id: message.id)
    expect(response).to have_http_status(:ok)
    expect(response.body).
      to include('Choose another file from this reply if you’d like to ' \
                 'share it too.')
    expect(response.body).
      not_to include('Nothing here looks like the decision or the records.')
  end
end
