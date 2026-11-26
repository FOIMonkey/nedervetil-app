require 'spec_helper'

RSpec.describe 'Disclosures visibility' do
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
      pages: [AttachmentFixtures.letter_page(secret: 'Repairs were completed ' \
                                                     'in the North ward')]
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

  def make_document(by: owner, from: attachment)
    document_from_attachment(from, by: by, ready: false)
  end

  def document_in(state)
    document = make_document
    return document.reload if state == :draft

    publish(document, by: admin)
    case state
    when :withdrawn
      Disclosures::Publication.new(document, user: owner).
        withdraw!(reason: 'Synthetic: changed my mind')
    when :attachment_requester_only
      FoiAttachment.find(attachment.id).
        update!(prominence: 'requester_only', prominence_reason: 'Hidden')
    when :reply_hidden
      message.update!(prominence: 'hidden', prominence_reason: 'Hidden')
    when :request_hidden
      info_request.update!(prominence: 'hidden', prominence_reason: 'Hidden')
    end
    document.reload
  end

  def paths(document)
    id = document.public_id
    ["/documents/#{id}", "/documents/#{id}/download",
     "/documents/#{id}/pages/1", "/documents/#{id}/thumbnail",
     "/documents/#{id}/manage"]
  end

  expected = {
    draft: {
      visitor: [404, 404, 404, 404, 302],
      other: [404, 404, 404, 404, 404],
      requester: [404, 404, 404, 404, 200],
      banned_requester: [404, 404, 404, 404, 200],
      admin: [404, 404, 404, 404, 200]
    },
    published: {
      visitor: [200, 200, 200, 200, 302],
      other: [200, 200, 200, 200, 404],
      requester: [200, 200, 200, 200, 200],
      banned_requester: [200, 200, 200, 200, 200],
      admin: [200, 200, 200, 200, 200]
    },
    withdrawn: {
      visitor: [410, 404, 404, 404, 302],
      other: [410, 404, 404, 404, 404],
      requester: [410, 404, 404, 404, 200],
      banned_requester: [410, 404, 404, 404, 200],
      admin: [410, 404, 404, 404, 200]
    },
    attachment_requester_only: {
      visitor: [410, 404, 404, 404, 302],
      other: [410, 404, 404, 404, 404],
      requester: [410, 404, 404, 404, 200],
      banned_requester: [410, 404, 404, 404, 200],
      admin: [410, 404, 404, 404, 200]
    },
    reply_hidden: {
      visitor: [410, 404, 404, 404, 302],
      other: [410, 404, 404, 404, 404],
      requester: [410, 404, 404, 404, 404],
      banned_requester: [410, 404, 404, 404, 404],
      admin: [410, 404, 404, 404, 200]
    },
    request_hidden: {
      visitor: [410, 404, 404, 404, 302],
      other: [410, 404, 404, 404, 404],
      requester: [410, 404, 404, 404, 404],
      banned_requester: [410, 404, 404, 404, 404],
      admin: [410, 404, 404, 404, 200]
    }
  }

  expected.each do |state, actors|
    it "answers each reader of a #{state.to_s.tr('_', ' ')} document " \
       'immediately without sync lag' do
      document = document_in(state)
      got = {}
      actors.each_key do |actor|
        case actor
        when :visitor then reset!
        when :other then sign_in(other)
        when :requester then sign_in(owner)
        when :admin then sign_in(admin)
        when :banned_requester
          owner.update_column(:ban_text, 'Synthetic ban')
          sign_in(owner)
        end
        got[actor] = paths(document).map do |path|
          document_request(:get, path)
          response.status
        end
        owner.update_column(:ban_text, '') if actor == :banned_requester
      end
      expect(got).to eq(actors)
    end
  end

  it 'hides private request details on public document pages and shows them ' \
     'only on the manage page for requester and admins' do
    document = document_in(:published)

    reset!
    get disclosure_document_path(document)
    expect(response).to have_http_status(:ok)
    expect(response.body).not_to include(info_request.url_title)
    expect(response.body).not_to include(owner.name)

    sign_in(owner)
    get disclosure_manage_document_path(document)
    expect(response).to have_http_status(:ok)
    expect(response.body).to include(info_request.url_title)
  end

  it 'keeps a document made by an admin from a hidden attachment out of ' \
     'the requester’s sight' do
    attachment.update!(prominence: 'hidden', prominence_reason: 'Admin only')
    document = make_document(by: admin)

    sign_in(owner)
    get disclosure_manage_document_path(document)
    expect(response).to have_http_status(:not_found)

    sign_in(admin)
    document_request(:get, disclosure_manage_document_path(document))
    expect(response).to have_http_status(:ok)
  end
end
