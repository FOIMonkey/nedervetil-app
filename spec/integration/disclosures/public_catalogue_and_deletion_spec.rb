require 'spec_helper'

RSpec.describe 'One-file public catalogue and request deletion',
               type: :request do
  include ActiveJob::TestHelper
  include_context 'with document OCR off'

  let(:requester) { FactoryBot.create(:user) }
  let(:body) { FactoryBot.create(:public_body) }
  let(:info_request) do
    FactoryBot.create(:info_request, user: requester, public_body: body)
  end

  def deliver_reply(files:, body_text: 'Please see the attached response.')
    AttachmentFixtures.deliver(info_request, files, text: body_text)
  end

  it 'serves thread and public download from one blob, applies public masks ' \
     'in place, renders pages on publish, and purges them on unpublish' do
    blue_rule = CensorRule.create!(text: 'BlueOnlySecret',
                                   replacement: '[blue]',
                                   colour: 'blue', censorable: info_request,
                                   last_edit_editor: 'admin',
                                   last_edit_comment: 'blue rule')

    pdf_bytes = DocumentFixtures.text_pdf(
      title: 'Public report',
      paragraphs: ['Public report with BlueOnlySecret and contact@example.com']
    )
    message = deliver_reply(
      files: [['report.pdf', 'application/pdf', pdf_bytes]]
    )
    attachment = message.get_attachments_for_display.first
    original_blob_id = attachment.file.blob_id
    original_bytes = attachment.file.download.b

    expect(attachment.prominence).to eq('requester_only')
    expect(attachment.body).to include('BlueOnlySecret')

    document = Disclosures::Creation.new(
      user: requester, attachment: attachment, kind: 'released_records'
    ).create!

    expect(document.pages.count).to eq(0)
    expect(document.thumbnail).not_to be_attached
    expect(document.listed?).to be(false)

    Disclosures::RequesterPublication.publish!(document, user: requester)
    attachment.reload
    document.reload

    expect(attachment.prominence).to eq('public')
    expect(document.listed?).to be(true)
    expect(document.pages.count).to eq(1)
    expect(document.pages.first.image).to be_attached
    expect(document.thumbnail).to be_attached
    expect(document.pages.first.text).not_to include('BlueOnlySecret')
    expect(document.pages.first.text).not_to include('contact@example.com')
    expect(attachment.file.blob_id).not_to eq(original_blob_id)
    expect(attachment.file.download.b).not_to eq(original_bytes)
    expect(Disclosures::RuleCheck.pdf_match?(attachment,
                                             attachment.file.download,
                                             [blue_rule])).to be(false)

    search = Disclosures::Search.new(q: 'Public report')
    expect(search.results.map(&:id)).to include(document.id)
    expect(search.hits[document.id]).not_to be_empty

    get disclosure_document_path(document)
    expect(response).to have_http_status(:ok)

    get disclosure_document_download_path(document)
    expect(response).to have_http_status(:ok)
    expect(response.body.b).to eq(attachment.file.download.b)

    get disclosure_document_page_path(document, page: 1)
    expect(response).to have_http_status(:ok)
    expect(response.content_type).to include('image/png')

    get disclosure_document_thumbnail_path(document)
    expect(response).to have_http_status(:ok)
    expect(response.content_type).to include('image/png')

    Disclosures::Publication.new(document, user: requester).
      withdraw!(reason: 'Taking down')
    attachment.reload
    document.reload

    expect(attachment.prominence).to eq('requester_only')
    expect(document.listed?).to be(false)
    expect(document.pages.count).to eq(0)
    expect(document.thumbnail).not_to be_attached
    expect(Disclosures::Search.new(q: 'Public report').results).to be_empty

    get disclosure_document_path(document)
    expect(response).to have_http_status(:gone)

    get disclosure_document_download_path(document)
    expect(response).to have_http_status(:not_found)

    get disclosure_document_page_path(document, page: 1)
    expect(response).to have_http_status(:not_found)

    get disclosure_document_thumbnail_path(document)
    expect(response).to have_http_status(:not_found)
  end

  it 'publishes reply main body text through the same FoiAttachment path' do
    CensorRule.create!(text: 'BlueBodyTerm', replacement: '[blue]',
                       colour: 'blue', censorable: info_request,
                       last_edit_editor: 'admin',
                       last_edit_comment: 'blue rule')
    message = deliver_reply(
      files: [],
      body_text: 'Decision: released. BlueBodyTerm and person@example.org.'
    )
    main = message.get_main_body_text_part
    document = Disclosures::Creation.new(
      user: requester, attachment: main, kind: 'decision_letter',
      email_text: true
    ).create!

    Disclosures::Publication.new(document, user: requester).publish!
    main.reload
    document.reload

    expect(main.prominence).to eq('public')
    expect(main.body_as_text.string).to include('[blue]')
    expect(main.body_as_text.string).not_to include('BlueBodyTerm')
    expect(main.body_as_text.string).not_to include('person@example.org')
    expect(document.pages.count).to eq(1)

    get disclosure_document_download_path(document)
    expect(response).to have_http_status(:ok)
    expect(response.body).to eq(main.file.download)
  end

  it 'detaches public FoiAttachments on request deletion while destroying ' \
     'private attachments, drafts, replies, and RawEmails' do
    message = deliver_reply(
      files: [
        ['public.txt', 'text/plain', 'Public spending report 2026'],
        ['private.txt', 'text/plain', 'Private draft notes']
      ]
    )
    public_part = message.foi_attachments.find_by!(filename: 'public.txt')
    private_part = message.foi_attachments.find_by!(filename: 'private.txt')
    raw_email_id = message.raw_email_id

    public_doc = Disclosures::Creation.new(
      user: requester, attachment: public_part, kind: 'released_records'
    ).create!
    Disclosures::Publication.new(public_doc, user: requester).publish!

    private_doc = Disclosures::Creation.new(
      user: requester, attachment: private_part, kind: 'released_records'
    ).create!

    kept = Disclosures::RequestDeletion.new(info_request, requester).delete!

    expect(kept.map(&:id)).to eq([public_doc.id])
    expect(InfoRequest.exists?(info_request.id)).to be(false)
    expect(IncomingMessage.exists?(message.id)).to be(false)
    expect(RawEmail.exists?(raw_email_id)).to be(false)
    expect(FoiAttachment.exists?(private_part.id)).to be(false)
    expect(Disclosures::Document.exists?(private_doc.id)).to be(false)

    public_part.reload
    public_doc.reload
    expect(public_part.incoming_message_id).to be_nil
    expect(public_part.prominence).to eq('public')
    expect(public_doc.foi_attachment_id).to eq(public_part.id)
    expect(public_doc.info_request_id).to be_nil
    expect(public_doc.incoming_message_id).to be_nil
    expect(public_doc.owner_id).to eq(requester.id)
    expect(public_doc.public_body_id).to eq(body.id)
    expect(public_doc.request_deleted?).to be(true)
    expect(public_doc.listed?).to be(true)

    expect(Disclosures::Search.new(q: 'spending report').results.map(&:id)).
      to eq([public_doc.id])
    if defined?(RequestJourney::Suggestions)
      expect(RequestJourney::Suggestions.new(body, 'spending report').
        documents.map(&:public_id)).to eq([public_doc.public_id])
    end

    get disclosure_document_path(public_doc)
    expect(response).to have_http_status(:ok)

    get disclosure_document_download_path(public_doc)
    expect(response).to have_http_status(:ok)
    expect(response.body).to eq('Public spending report 2026')
  end

  it 'renders an image attachment through Disclosures::Renderer::Image' do
    png = AttachmentFixtures.image(lines: [[10, 40, 'Photo']], width: 200,
                                   height: 100)
    message = deliver_reply(files: [['photo.png', 'image/png', png]])
    part = message.get_attachments_for_display.first
    document = Disclosures::Document.create!(
      info_request: info_request,
      public_body: body,
      incoming_message: message,
      foi_attachment: part,
      source_kind: 'attachment',
      kind: 'released_records',
      title: 'Photo release',
      released_on: Date.current
    )

    Disclosures::Publication.new(document, user: requester).publish!
    document.reload

    expect(document.format).to eq('image')
    expect(document.page_count).to eq(1)
    expect(document.pages.first.image).to be_attached
    expect(document.thumbnail).to be_attached
  end

  describe 'requester self-deletion blockers' do
    let(:admin_hidden_msg) do
      'Part of this request was hidden by an admin. ' \
        'Ask the site’s admins to delete it.'
    end

    def expect_blocked!(expected = admin_hidden_msg)
      deletion = Disclosures::RequestDeletion.new(info_request.reload,
                                                  requester)
      expect(deletion.blockers).to include(expected)
      expect { deletion.delete! }.
        to raise_error(Disclosures::Error::Refused, include(expected))

      sign_in(requester)
      post request_deletion_path(url_title: info_request.url_title),
           params: { confirm: '1' }
      expect(response).
        to redirect_to(request_deletion_path(url_title: info_request.url_title))
      expect(InfoRequest.exists?(info_request.id)).to be(true)
    end

    it 'blocks requester deletion when an attachment is hidden by an admin' do
      message = deliver_reply(files: [['secret.txt', 'text/plain', 'Hidden']])
      part = message.foi_attachments.find_by!(filename: 'secret.txt')
      part.update!(prominence: 'hidden', prominence_reason: 'Admin hide')

      expect_blocked!
    end

    it 'allows requester deletion when masking failed on an unhidden attachment' do
      message = deliver_reply(files: [['fault.txt', 'text/plain', 'Secret']])
      part = message.foi_attachments.find_by!(filename: 'fault.txt')
      part.update_columns(masking_failed_at: Time.zone.now)

      deletion = Disclosures::RequestDeletion.new(info_request.reload,
                                                  requester)
      expect(deletion.blockers).to be_empty
      deletion.delete!
      expect(InfoRequest.exists?(info_request.id)).to be(false)
    end

    it 'blocks requester deletion when an incoming message is hidden by an admin' do
      message = deliver_reply(files: [['reply.txt', 'text/plain', 'Content']])
      message.update!(prominence: 'hidden', prominence_reason: 'Admin hide')

      expect_blocked!
    end

    it 'blocks requester deletion when a document is admin-hidden via a moved reply' do
      message = deliver_reply(files: [['doc.txt', 'text/plain', 'Content']])
      part = message.foi_attachments.find_by!(filename: 'doc.txt')
      Disclosures::Creation.new(
        user: requester, attachment: part, kind: 'released_records'
      ).create!
      other_request = FactoryBot.create(:info_request)
      message.update!(info_request: other_request)

      expect_blocked!
    end

    it 'blocks requester deletion when the requester has an open draft' do
      message = deliver_reply(files: [['notes.txt', 'text/plain', 'Original']])
      part = message.foi_attachments.find_by!(filename: 'notes.txt')
      AttachmentManagement::Revision.create!(
        foi_attachment: part,
        user: requester,
        kind: 'text_edit',
        status: 'ready',
        source_sha256: Digest::SHA256.hexdigest(part.body),
        source_content_type: 'text/plain',
        source_filename: 'notes.txt'
      )

      expect_blocked!('Save or discard your changes to notes.txt first.')
    end
  end
end
