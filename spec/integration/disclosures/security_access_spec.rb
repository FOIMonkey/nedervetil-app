require 'spec_helper'

# The requester is treated as possibly hostile.
RSpec.describe 'Disclosures security and access' do
  include ActiveJob::TestHelper
  include DisclosuresHelpers
  include_context 'with document OCR off'
  include_context 'with a separate Manage workspace'
  include_context 'with production error pages'

  let(:owner) do
    FactoryBot.create(:user, name: 'Rowan Requester', trusted: true)
  end
  let(:admin) { FactoryBot.create(:admin_user) }
  let(:other) { FactoryBot.create(:user, name: 'Morgan Newowner') }
  let(:info_request) do
    FactoryBot.create(:info_request, user: owner, title: 'Gritting routes 2024')
  end
  let(:text) { "Gritting by ward\nNorth: 12 runs\nOfficer: Jane Placeholder\n" }
  let(:redacted) { text.sub('Jane Placeholder', '[redacted]') }

  around do |example|
    keeping_settings(Disclosures, :daily_documents) do
      example.run
    end
  end

  def path(document, rest = '')
    "/documents/#{document.public_id}#{rest}"
  end

  def make_document(name = 'runs.txt', request: info_request)
    delivered_document(request, name, 'text/plain', text)
  end

  # The document as a request loaded it, before another user's change was saved.
  def loaded_now(document)
    Disclosures::Document.find(document.id).tap(&:info_request)
  end

  def serve_stale(loaded)
    allow(Disclosures::Document).to receive(:find_public!).and_return(loaded)
  end

  describe 'a change that lands after another one' do
    it 'refuses a requester’s edit or delete checked on a draft that was published meanwhile' do
      document = make_document
      for_edit = loaded_now(document)
      for_delete = loaded_now(document)
      publish(document, by: admin)
      expect(Ability.new(owner).can?(:edit_document, for_edit)).to be true

      sign_in(owner)
      serve_stale(for_edit)
      document_request :patch, path(document),
            params: { document: { title: 'Retitled after publication' } }
      expect(response).to have_http_status(:not_found)
      expect(document.reload.title).not_to eq('Retitled after publication')
      expect(document.events.where(action: 'details_changed')).to be_empty

      expect(Ability.new(owner).can?(:delete_document, for_delete)).to be true
      serve_stale(for_delete)
      document_request :delete, path(document), params: { confirm: '1' }
      expect(response).to have_http_status(:not_found)
      expect(Disclosures::Document.find(document.id)).to be_listed
    end

    it 'still saves a requester’s edit to a draft' do
      document = make_document
      sign_in(owner)
      document_request :patch, path(document),
            params: { document: { title: 'Gritting runs by ward' } }
      expect(response).to redirect_to(path(document, '/manage'))
      expect(document.reload.title).to eq('Gritting runs by ward')
    end

    it 'refuses a withdrawal by someone who stopped being the requester meanwhile' do
      document = publish(make_document, by: admin)
      for_withdraw = loaded_now(document)
      info_request.update_column(:user_id, other.id)

      sign_in(owner)
      serve_stale(for_withdraw)
      document_request :post, path(document, '/withdraw'),
           params: { reason: 'Synthetic: no longer mine' }
      expect(response).to have_http_status(:not_found)
      expect(document.reload.state).to eq('published')
    end
  end

  describe 'who redacted, after the request changes hands' do
    include_context 'with the publish flow off'

    it 'keeps a thread redaction’s redactor as recorded when the draft was made' do
      letter = AttachmentFixtures.pdf(
        pages: [AttachmentFixtures.letter_page(secret: 'Jane Placeholder')]
      )
      message = AttachmentFixtures.deliver(
        info_request, [['letter.pdf', 'application/pdf', letter]]
      )
      notes = message.get_attachments_for_display.
        find { |a| a.filename == 'letter.pdf' }
      sign_in(owner)
      boxes = { '1' => [AttachmentFixtures.letter_secret_box] }.to_json
      document_request :post, manage_attachment_revisions_path(notes),
           params: { kind: 'pdf_redaction', boxes: boxes }
      perform_enqueued_jobs(only: AttachmentManagement::ProcessJob)
      draft = AttachmentManagement::Revision.
        where(foi_attachment_id: notes.id).last
      expect(draft).to be_ready
      expect(draft.instructions).to include('by_requester' => true)
      document_request :post,
                       apply_manage_attachment_revision_path(notes, draft),
           params: { reason: 'Synthetic', reviewed: '1',
                     output_sha256: draft.output_sha256 }
      expect(draft.reload).to be_applied

      info_request.update_column(:user_id, other.id)
      expect(
        AttachmentManagement::Attribution.new(FoiAttachment.find(notes.id)).text
      ).to eq('Redacted by the requester')
    end
  end

  it 'routes requesters on RevisionsController to the publish flow when requester editing is on' do
    message = AttachmentFixtures.deliver(info_request,
                                         [['notes.txt', 'text/plain', text]])
    notes = message.get_attachments_for_display.
      find { |a| a.filename == 'notes.txt' }
    sign_in(owner)
    post manage_attachment_revisions_path(notes),
         params: { kind: 'text_edit', text: redacted }
    expect(response).to redirect_to(
      publish_reply_path(url_title: info_request.url_title,
                         message_id: message.id)
    )
  end
end
