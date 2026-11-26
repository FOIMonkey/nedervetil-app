require 'spec_helper'

RSpec.describe 'Disclosures and suspended accounts' do
  include ActiveJob::TestHelper
  include DisclosuresHelpers
  include_context 'with document OCR off'
  include_context 'with production error pages'

  let(:owner) { FactoryBot.create(:user, name: 'Rowan Requester') }
  let(:admin) { FactoryBot.create(:admin_user) }
  let(:info_request) do
    FactoryBot.create(:info_request, user: owner, title: 'Pothole repairs 2024')
  end
  let(:message) do
    pdf = AttachmentFixtures.pdf(
      pages: [
        { texts: [{ x: 72, y: 700, text: 'Repairs by ward, 2024', size: 12 }] }
      ]
    )
    AttachmentFixtures.deliver(info_request,
                               [['repairs.pdf', 'application/pdf', pdf]])
  end
  let(:attachment) do
    message.get_attachments_for_display.
      find { |part| part.filename == 'repairs.pdf' }
  end

  def draft
    Disclosures::Creation.new(user: owner,
                              attachment: attachment,
                              kind: 'released_records').create!.reload
  end

  def published
    document = draft
    publish(document, by: admin)
    document.reload
  end

  it 'lets a banned requester withdraw their published document, and nothing else' do
    document = published
    owner.update!(ban_text: 'Banned for testing')
    sign_in(owner)

    get "/documents/#{document.public_id}/manage"
    expect(response).to have_http_status(:ok)
    expect(Nokogiri::HTML(response.body).css('summary').map(&:text)).
      to include('Withdraw (only an admin can share it again)')
    expect(response.body).not_to include('document-manage__facts')
    get "/documents/#{document.public_id}/edit"
    expect(response).to have_http_status(:not_found)

    post "/documents/#{document.public_id}/withdraw",
         params: { reason: 'My personal details are in it' }
    expect(document.reload.state).to eq('withdrawn')
  end

  # #90, question 2: a suspended requester may still delete a draft.
  it 'lets a banned requester see and delete their draft, and not edit it' do
    with_setting(Disclosures, :requester_editing, true) do
      document = draft
      owner.update!(ban_text: 'Banned for testing')
      sign_in(owner)

      get "/documents/#{document.public_id}/manage"
      expect(response).to have_http_status(:ok)
      expect(response.body).not_to include('document-manage__facts')
      expect(Nokogiri::HTML(response.body).css('summary').map(&:text)).
        to include(a_string_including('Delete this draft'))
      get "/documents/#{document.public_id}/edit"
      expect(response).to have_http_status(:not_found)

      delete "/documents/#{document.public_id}/manage",
             params: { confirm: '1' }
      expect(Disclosures::Document.exists?(document.id)).to be(false)
    end
  end

  it 'treats a requester who has closed their account as a visitor' do
    document = draft
    sign_in(owner)
    get "/documents/#{document.public_id}/manage"
    expect(response).to have_http_status(:ok)

    owner.close!
    get "/documents/#{document.public_id}"
    expect(response).to have_http_status(:not_found)
    sign_in(owner)
    get "/documents/#{document.public_id}"
    expect(response).to have_http_status(:not_found)
  end
end
