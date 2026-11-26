require 'spec_helper'

RSpec.describe 'Attachment management screens' do
  # Requesters reach the thread editor's screens when the publish flow is off.
  include_context 'with the publish flow off'
  include ActiveJob::TestHelper

  include_context 'with a separate Manage workspace'

  before do
    allow(Rails.application.config).
      to receive(:consider_all_requests_local).and_return(false)
  end

  let(:owner) { FactoryBot.create(:user) }
  let(:admin) { FactoryBot.create(:admin_user) }
  let(:other) { FactoryBot.create(:user) }
  let(:info_request) { FactoryBot.create(:info_request, user: owner) }
  let(:letter) do
    AttachmentFixtures.pdf(
      pages: [
        AttachmentFixtures.letter_page(secret: 'Case officer: Jane Example'),
        AttachmentFixtures.letter_page(secret: 'Witness: John Sample',
                                       heading: 'Annex A')
      ],
      info: { Author: 'Jane Example' }
    )
  end
  let(:notes) { "Call Jane Example on 01632 960123.\nNothing else here.\n" }
  let(:files) do
    [['letter.pdf', 'application/pdf', letter],
     ['notes.txt', 'text/plain', notes]]
  end
  let(:message) { AttachmentFixtures.deliver(info_request, files) }
  let(:pdf) { attachment('letter.pdf') }
  let(:text_file) { attachment('notes.txt') }

  def attachment(name)
    message.get_attachments_for_display.find { |a| a.filename == name }
  end

  def version(record)
    Digest::SHA256.hexdigest(FoiAttachment.find(record.id).body.to_s)
  end

  def draft!(record, **params)
    params = { source_sha256: version(record) }.merge(params)
    post manage_attachment_revisions_path(record), params: params
    perform_enqueued_jobs(only: AttachmentManagement::ProcessJob)
    AttachmentManagement::Revision.where(foi_attachment_id: record.id).
      order(:id).last&.reload
  end

  def redact!(record, boxes = { '1' => [AttachmentFixtures.letter_secret_box] }, **params)
    draft!(record, kind: 'pdf_redaction', boxes: boxes.to_json, **params)
  end

  def confirm!(record, draft, sha: draft.output_sha256, reason: 'Remove names (synthetic)', **params)
    post apply_manage_attachment_revision_path(record, draft),
         params: { output_sha256: sha, reason: reason, reviewed: '1',
                   **params }
  end

  # The first download masks an attachment in a background job. Reading the
  # body of a fresh record masks it now; a record just parsed caches its raw
  # body and skips masking.
  def served(record)
    FoiAttachment.find(record.id).body
    get attachment_path_for(record)
    expect(response).to have_http_status(:ok)
    response.body.b
  end

  def attachment_path_for(record)
    record.reload
    "/request/#{record.info_request.url_title}/response/" \
      "#{record.incoming_message_id}/attach/#{record.url_part_number}/" \
      "#{ERB::Util.url_encode(record.display_filename)}"
  end

  describe 'opening the current file' do
    before { sign_in(owner) }

    it 'offers inline viewing for PDF and plain text files' do
      [pdf, text_file].each do |record|
        get manage_attachment_path(record)
        expect(response).to have_http_status(:ok)
        links = Nokogiri::HTML(response.body).css('a').map { |a| a['href'] }
        expect(links).
          to include(manage_attachment_current_path(record, inline: 1),
                     manage_attachment_current_path(record))
      end
    end

    it 'offers only a download for an octet-stream file' do
      record = text_file
      record.update_column(:content_type, 'application/octet-stream')
      get manage_attachment_path(record)
      expect(response).to have_http_status(:ok)
      links = Nokogiri::HTML(response.body).css('a').map { |a| a['href'] }
      expect(links).to include(manage_attachment_current_path(record))
      expect(links).
        not_to include(manage_attachment_current_path(record, inline: 1))
    end
  end

  describe 'who can reach the screens' do
    it 'asks a visitor to sign in, without naming the attachment or request' do
      private_name = 'private_attachment_sentinel_20261103'
      delivered = AttachmentFixtures.deliver(
        info_request, [["#{private_name}.pdf", 'application/pdf', letter]]
      )
      record = delivered.get_attachments_for_display.first
      get manage_attachment_path(record)
      expect(response).to redirect_to(%r{/profile/sign_in})
      follow_redirect!
      expect(response.body).not_to include(private_name, info_request.title)
    end

    it 'gives a visitor a 404 for any change' do
      post manage_attachment_revisions_path(pdf), params: { kind: 'upload' }
      expect(response).to have_http_status(:not_found)
    end

    it 'gives another account a 404 on every route, including an existing draft' do
      sign_in(owner)
      draft = redact!(pdf)
      sign_in(other)
      routes = [
        [:get, manage_attachment_path(pdf)],
        [:get, manage_attachment_current_path(pdf)],
        [:get, manage_attachment_page_path(pdf, page: 1)],
        [:get, manage_attachment_redact_path(pdf)],
        [:get, manage_attachment_text_path(text_file)],
        [:post, manage_attachment_revisions_path(pdf)],
        [:get, manage_attachment_revision_path(pdf, draft)],
        [:get, file_manage_attachment_revision_path(pdf, draft)],
        [:get, page_manage_attachment_revision_path(pdf, draft, page: 1)],
        [:post, apply_manage_attachment_revision_path(pdf, draft)],
        [:post, discard_manage_attachment_revision_path(pdf, draft)]
      ]
      routes.each do |verb, path|
        send(verb, path, params: { output_sha256: draft.output_sha256,
                                   reason: 'x', reviewed: '1' })
        expect(response).to have_http_status(:not_found),
                            "#{verb} #{path} gave #{response.status}"
      end
      expect(AttachmentManagement::Revision.
               where(foi_attachment_id: pdf.id, status: 'applied')).to be_empty
      expect(draft.reload).to be_ready
    end

    it 'does not find a draft through another attachment of the same request' do
      sign_in(owner)
      draft = redact!(pdf)
      get manage_attachment_revision_path(text_file, draft)
      expect(response).to have_http_status(:not_found)
    end

    it 'shows Manage beside every attachment to the requester only, and "Edit message text" to neither' do
      message
      sign_in(owner)
      get "/request/#{info_request.url_title}"
      page = Nokogiri::HTML(response.body)
      expect(page.css('a.attachment__manage').map { |a| a['href'] }).
        to match_array([manage_attachment_path(pdf),
                        manage_attachment_path(text_file)])
      expect(page.css('.attachment-management-body-link')).to be_empty

      sign_in(other)
      get "/request/#{info_request.url_title}"
      expect(Nokogiri::HTML(response.body).
               css('a.attachment__manage, .attachment-management-body-link')).
        to be_empty
    end

    it 'keeps an admin-only attachment from the requester, but not from an admin' do
      pdf.update!(prominence: 'hidden', prominence_reason: 'Synthetic')
      sign_in(owner)
      get manage_attachment_path(pdf)
      expect(response).to have_http_status(:not_found)
      sign_in(admin)
      get manage_attachment_path(pdf)
      expect(response).to have_http_status(:ok)
    end
  end

  describe 'redacting a PDF' do
    before { sign_in(owner) }

    it 'shows the pages of the current file to draw on' do
      get manage_attachment_redact_path(pdf)
      expect(response).to have_http_status(:ok)
      expect(Nokogiri::HTML(response.body).css('.redaction-page').size).to eq(2)
      get manage_attachment_page_path(pdf, page: 2)
      expect(response.media_type).to eq('image/png')
      expect(response.headers['Cache-Control']).to include('no-store')
    end

    it 'makes a draft without touching the attachment, then replaces it with exactly that file' do
      before = served(pdf)
      draft = redact!(pdf, { '1' => [AttachmentFixtures.letter_secret_box],
                             '2' => [AttachmentFixtures.letter_secret_box] })

      expect(draft).to be_ready
      expect(draft.report).to include('boxes' => 2, 'boxes_verified' => 2,
                                      'text_characters' => 0, 'fonts' => 0)
      expect(served(pdf)).to eq(before)

      get manage_attachment_revision_path(pdf, draft)
      expect(response.body).to include('Ready to check', draft.output_sha256)

      confirm!(pdf, draft)
      expect(response).to redirect_to(foi_attachment_path(pdf))
      after = served(pdf)
      expect(Digest::SHA256.hexdigest(after)).to eq(draft.output_sha256)
      expect(after).not_to eq(before)
      expect(pdf.reload.display_size).to eq("#{draft.output_byte_size / 1024}K")
      expect(draft.reload).to be_applied
    end

    it 'logs the replacement in core’s audit trail with the editor and reason' do
      draft = redact!(pdf)
      confirm!(pdf, draft, reason: 'Remove the case officer (synthetic)')
      event = info_request.info_request_events.
        where(event_type: 'edit_attachment').last
      expect(event.params).to include(
        reason: 'Remove the case officer (synthetic)',
        attachment_management_revision_id: draft.id,
        output_sha256: draft.output_sha256
      )
      expect(event.params[:foi_attachment]).to eq(pdf)
      expect(event.params[:editor]).to eq(owner)
      expect(draft.reload.info_request_event).to eq(event)
    end

    it 'never changes who can see the attachment' do
      before = message.reload.prominence
      draft = redact!(pdf)
      confirm!(pdf, draft)
      expect(info_request.reload.prominence).to eq('requester_only')
      expect(message.reload.prominence).to eq(before)
      expect(pdf.reload.prominence).to eq('requester_only')
      expect(Ability.new(other).can?(:read, pdf)).to be false
    end

    it 'refuses a confirmation that skips the reviewed checkbox' do
      draft = redact!(pdf)
      post apply_manage_attachment_revision_path(pdf, draft),
           params: { reason: 'x' }
      expect(flash[:error]).to include('Tick the box')
      expect(draft.reload).to be_ready
    end

    it 'needs a new confirmation once the attachment has changed' do
      first = redact!(pdf)
      second = redact!(pdf, { '2' => [AttachmentFixtures.letter_secret_box] })
      confirm!(pdf, second)
      expect(first.reload).to be_superseded
      expect(first.output).not_to be_attached

      confirm!(pdf, first, sha: first.output_sha256 || 'x')
      expect(flash[:error]).to be_present
      expect(Digest::SHA256.hexdigest(served(pdf))).
        to eq(second.output_sha256)
    end

    it 'builds a repeated redaction on the last confirmed version' do
      first = redact!(pdf, { '1' => [AttachmentFixtures.letter_secret_box] })
      confirm!(pdf, first)
      second = redact!(pdf, { '2' => [AttachmentFixtures.letter_secret_box] })
      expect(second.source_sha256).to eq(first.output_sha256)
      confirm!(pdf, second)

      Dir.mktmpdir do |dir|
        File.binwrite("#{dir}/a.pdf", served(pdf))
        pages = AttachmentFixtures.render_pages("#{dir}/a.pdf", dir)
        expect(AttachmentFixtures.region(
          pages[0], AttachmentFixtures.letter_secret_box
        )[:max]).to be <= 0.05
        expect(AttachmentFixtures.region(
          pages[1], AttachmentFixtures.letter_secret_box
        )[:max]).to be <= 0.05
      end
      expect(info_request.info_request_events.
               where(event_type: 'edit_attachment').count).to eq(2)
    end

    it 'clears the page images of the old file when a replacement is confirmed' do
      get manage_attachment_page_path(pdf, page: 1)
      expect(Dir[File.join(AttachmentManagement.workspace, pdf.id.to_s, '*')]).
        not_to be_empty
      confirm!(pdf, redact!(pdf))
      expect(File.exist?(File.join(AttachmentManagement.workspace,
                                   pdf.id.to_s))).to be false
    end

    it 'refuses to start a draft for a PDF it can’t read' do
      pdf.replace_file!('%PDF-1.4 broken'.b)
      post manage_attachment_revisions_path(pdf),
           params: { kind: 'pdf_redaction', boxes: '{}' }
      expect(flash[:error]).to include('can’t be read as a PDF')
      expect(AttachmentManagement::Revision.count).to eq(0)
    end

    it 'fails a draft whose processing fails, and leaves the attachment as it was' do
      before = served(pdf)
      allow_any_instance_of(AttachmentManagement::Engines::Raster).
        to receive(:redact_pdf).
        and_raise(AttachmentManagement::Command::Failed,
                  'pdftoppm: exit 1: synthetic failure')
      draft = redact!(pdf)
      expect(draft).to be_failed
      expect(draft.error).to include('synthetic failure')
      expect(draft.output).not_to be_attached
      expect(served(pdf)).to eq(before)

      get manage_attachment_revision_path(pdf, draft)
      expect(response.body).to include('The attachment hasn’t changed')
    end

    it 'rejects boxes for pages the file does not have' do
      post manage_attachment_revisions_path(pdf),
           params: {
             kind: 'pdf_redaction',
             boxes: { '9' => [AttachmentFixtures.letter_secret_box] }.to_json,
             source_sha256: version(pdf)
           }
      expect(flash[:error]).to include('no page 9')
      expect(AttachmentManagement::Revision.count).to eq(0)
    end
  end

  describe 'a PDF that needs a password' do
    let(:files) do
      [['locked.pdf', 'application/pdf',
        AttachmentFixtures.encrypted_pdf(letter)]]
    end

    it 'explains, and still offers the upload to an admin' do
      sign_in(owner)
      get manage_attachment_path(attachment('locked.pdf'))
      expect(response.body).
        to include('protected with a password',
                   'An admin can still upload a replacement')
      expect(response.body).not_to include('Draw redaction boxes</a>')
      sign_in(admin)
      get manage_attachment_path(attachment('locked.pdf'))
      expect(response.body).
        to include('protected with a password', 'Upload a replacement')
    end
  end

  describe 'editing text' do
    it 'replaces a text attachment with the edited text for an admin' do
      sign_in(admin)
      get manage_attachment_text_path(text_file)
      expect(response.body).to include('Call Jane Example')
      draft = draft!(text_file,
                     kind: 'text_edit',
                     text: "Call [redacted] on [redacted].\r\n" \
                           "Nothing else here.\r\n")
      expect(draft).to be_ready
      expect(draft.report).to include('lines_changed' => 2)
      confirm!(text_file, draft)
      expect(served(text_file)).
        to eq("Call [redacted] on [redacted].\nNothing else here.\n")
    end

    it 'refuses an unchanged text' do
      sign_in(admin)
      draft!(text_file, kind: 'text_edit', text: notes)
      expect(flash[:error]).to include('unchanged')
      expect(AttachmentManagement::Revision.count).to eq(0)
    end

    it 'gives the requester a 404 for the text of a file' do
      sign_in(owner)
      get manage_attachment_text_path(text_file)
      expect(response).to have_http_status(:not_found)
    end

    it 'gives the requester a 404 for the message text, and makes no draft' do
      sign_in(owner)
      body = message.get_main_body_text_part
      get manage_attachment_text_path(body)
      expect(response).to have_http_status(:not_found)
      draft!(body,
             kind: 'text_edit',
             text: "Please find our response attached.\n\n[redacted]\n")
      expect(AttachmentManagement::Revision.count).to eq(0)
    end

    it 'edits the message text itself, which is core’s main body attachment' do
      sign_in(admin)
      body = message.get_main_body_text_part
      draft = draft!(body,
                     kind: 'text_edit',
                     text: "Please find our response attached.\n\n[redacted]\n")
      confirm!(body, draft)
      expect(message.reload.get_main_body_text_folded).
        not_to include('Jane Example')
      get "/request/#{info_request.url_title}"
      expect(response.body).not_to include('Jane Example')
    end
  end

  describe 'uploading a replacement (an admin; requesters may only redact)' do
    before { sign_in(admin) }

    let(:new_pdf) do
      AttachmentFixtures.pdf(
        pages: [AttachmentFixtures.letter_page(secret: 'Reviewed copy')]
      )
    end

    def upload!(record, bytes, name, type)
      file = Rack::Test::UploadedFile.new(StringIO.new(bytes), type, true,
                                          original_filename: name)
      draft!(record, kind: 'upload', file: file)
    end

    it 'replaces a file with one of the same format under the same name' do
      draft = upload!(pdf, new_pdf, 'My local copy - Jane.pdf',
                      'application/pdf')
      expect(draft).to be_ready
      expect(draft).not_to be_format_change
      expect(draft.report['pdf']).to include('pages' => 1)
      confirm!(pdf, draft)
      expect(pdf.reload.filename).to eq('letter.pdf')
      expect(served(pdf)).to eq(new_pdf.b)
    end

    it 'asks the confirmation to accept a change of format, then changes the type and extension' do
      draft = upload!(text_file, new_pdf, 'notes.pdf', 'application/pdf')
      expect(draft).to be_format_change
      confirm!(text_file, draft)
      expect(flash[:error]).to include('change of format')
      expect(text_file.reload.content_type).to eq('text/plain')

      confirm!(text_file, draft, accept_format_change: '1')
      text_file.reload
      expect(text_file.content_type).to eq('application/pdf')
      expect(text_file.filename).to eq('notes.pdf')
      expect(served(text_file)).to eq(new_pdf.b)
    end

    it 'keeps a filename that a censor rule masks masked' do
      FactoryBot.create(:info_request_censor_rule, censorable: info_request,
                                                   text: 'Jane Example',
                                                   replacement: 'NAME')
      named = AttachmentFixtures.deliver(
        info_request, [['Jane Example letter.pdf', 'application/pdf', letter]]
      ).get_attachments_for_display.first
      expect(named.display_filename).to eq('NAME letter.pdf')
      confirm!(named, upload!(named, new_pdf, 'Jane Example letter.pdf',
                              'application/pdf'))
      expect(named.reload.display_filename).to eq('NAME letter.pdf')
      expect(named.filename).not_to include('Jane')
    end

    it 'turns away an empty file' do
      upload!(pdf, '', 'empty.pdf', 'application/pdf')
      expect(flash[:error]).to include('empty')
    end
  end

  describe 'an Office document' do
    let(:files) do
      [['briefing.docx',
        'application/vnd.openxmlformats-officedocument.' \
        'wordprocessingml.document',
        AttachmentFixtures.docx(
          paragraphs: ['Briefing note', 'Prepared by DOCXSECRET Person.']
        )]]
    end
    let(:docx) { attachment('briefing.docx') }

    before { sign_in(admin) }

    it 'lists what the file hides, converts it, and redacts the PDF into a replacement' do
      get manage_attachment_path(docx)
      expect(response.body).to include('2 tracked changes', '1 comment',
                                       'Author in document properties')

      converted = draft!(docx, kind: 'office_pdf')
      expect(converted).to be_ready
      expect(converted.output_content_type).to eq('application/pdf')
      expect(converted.report['office_findings']).
        to include('2 tracked changes')

      get manage_attachment_redact_path(docx, from: converted.id)
      expect(response).to have_http_status(:ok)
      redacted = redact!(docx, { '1' => [[0.0, 0.0, 1.0, 0.5]] },
                         parent_id: converted.id)
      expect(redacted).to be_ready
      expect(redacted.parent).to eq(converted)

      confirm!(docx, redacted, accept_format_change: '1')
      docx.reload
      expect(docx.content_type).to eq('application/pdf')
      expect(docx.filename).to eq('briefing.pdf')
      expect(converted.reload).to be_superseded
    end
  end

  describe 'a batch request' do
    let(:pro_owner) do
      FactoryBot.create(:pro_user, trusted: true)
    end
    let(:batch) do
      FactoryBot.create(:info_request_batch, :sent, user: pro_owner,
                                                    public_body_count: 2)
    end
    let(:child) { batch.info_requests.order(:id).first }
    let!(:child_pdf) do
      AttachmentFixtures.deliver(child,
                                 [['policy.pdf', 'application/pdf', letter]]).
        get_attachments_for_display.first
    end

    before do
      allow(AlaveteliFeatures.backend).to receive(:enabled?).and_call_original
      allow(AlaveteliFeatures.backend).to receive(:enabled?).
        with(:alaveteli_pro).and_return(true)
    end

    it 'manages each child’s attachments and the batch ZIP gives the new file' do
      sign_in(pro_owner)
      get "/request/#{child.url_title}"
      expect(Nokogiri::HTML(response.body).css('a.attachment__manage').
               map { |a| a['href'] }).
        to include(manage_attachment_path(child_pdf))
      draft = redact!(child_pdf)
      confirm!(child_pdf, draft)

      zip = InfoRequestBatchZip.new(batch, ability: Ability.new(pro_owner))
      file = zip.files.find { |f| f.path.end_with?('policy.pdf') }
      expect(Digest::SHA256.hexdigest(file.body)).to eq(draft.output_sha256)
    end
  end

  describe 'a confirmed text edit' do
    it 'updates the extracted text and masks the file' do
      message.get_attachment_text_full
      message.reload

      sign_in(admin)
      draft = draft!(text_file,
                     kind: 'text_edit',
                     text: "Call [redacted] on [redacted].\n" \
                           "Nothing else here.\n")
      confirm!(text_file, draft)

      expect(message.reload.get_attachment_text_full).
        not_to include('01632 960123')
      expect(text_file.reload.body).to include('Call [redacted]')
    end
  end
end
