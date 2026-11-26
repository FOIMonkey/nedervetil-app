require 'spec_helper'

RSpec.describe 'One working-copy editor, requester gate, and review setting' do
  include ActiveJob::TestHelper
  include DisclosuresHelpers
  include SettingsHelpers
  include_context 'with document OCR off'

  let(:owner) do
    FactoryBot.create(:user, name: 'Rowan Requester',
                             email: 'rowan.requester@example.org')
  end
  let(:admin) { FactoryBot.create(:admin_user) }
  let(:info_request) { FactoryBot.create(:info_request, user: owner) }

  def receive_reply(body:, files: {})
    mail = Mail.new
    mail.from = info_request.public_body.request_email
    mail.to = info_request.incoming_email
    mail.subject = 'Response'
    mail.text_part = Mail::Part.new(content_type: 'text/plain; charset=UTF-8',
                                    body: body)
    files.each do |filename, content|
      mail.add_file(filename: filename, content: content)
    end
    message = info_request.receive(Mail.from_source(mail.encoded))
    IncomingMessage::StoreTextJob.perform_now(message)
    message.reload
  end

  def make_document(attachment, title: nil, email_text: false)
    suggested = Disclosures::Titles.suggest('decision_letter', info_request,
                                            Date.current)
    Disclosures::Document.create!(
      info_request: info_request,
      public_body: info_request.public_body,
      incoming_message: attachment.incoming_message,
      foi_attachment: attachment,
      source_kind: email_text ? 'email_text' : 'attachment',
      kind: 'decision_letter',
      title: title || suggested,
      released_on: Date.current,
      state: 'draft',
      created_by: owner
    )
  end

  describe 'requester redaction gate on black_masked' do
    it 'allows redaction on unmasked files (including reply text) and blocks black-rule files' do
      message = receive_reply(
        body: 'Dear Rowan Requester, plain reply text.',
        files: { 'secret.txt' => 'Contains SecretWord here.' }
      )
      main_part = message.get_main_body_text_part
      secret_part = message.foi_attachments.find { _1.filename == 'secret.txt' }

      perform_enqueued_jobs do
        FactoryBot.create(:censor_rule, censorable: info_request,
                                        text: 'SecretWord',
                                        replacement: '[black]')
      end
      main_part.reload
      secret_part.reload

      ability = Ability.new(owner)
      expect(ability.can?(:manage_attachment, main_part)).to be(true)
      expect(ability.can?(:manage_attachment, secret_part)).to be(false)

      doc = make_document(secret_part, title: 'Black-masked file')
      expect(ability.can?(:redact_document, doc)).to be(false)

      sign_in owner
      get publish_reply_redact_path(url_title: info_request.url_title,
                                    message_id: message.id, id: doc)
      expect(response).to have_http_status(:ok)
      expect(response.body).
        to include('An admin has already redacted this file')

      post publish_reply_ask_admin_path(url_title: info_request.url_title,
                                        message_id: message.id, id: doc),
           params: { note: 'Please hide my address too' }
      expect(response).to have_http_status(:redirect)
      expect(Disclosures::ReviewSubmission.pending?(doc.reload)).to be(true)
    end

    it 'blocks requester redaction after an admin manually black-redacts a file' do
      message = receive_reply(body: 'Cover',
                              files: { 'note.txt' => 'Sensitive text here.' })
      part = message.foi_attachments.find { _1.filename == 'note.txt' }

      builder = AttachmentManagement::NewRevision.new(
        part, user: admin, ability: Ability.new(admin)
      )
      revision, input = builder.build('text_edit',
                                      text: '[redacted] text here.',
                                      black_mask: true)
      revision.save!
      revision.output.attach(io: StringIO.new(input.b), filename: 'input',
                             content_type: 'application/octet-stream')
      AttachmentManagement::Processor.new(revision).run
      AttachmentManagement::Replacement.new(
        revision.reload, editor: admin, reason: 'Third-party data'
      ).apply!

      expect(part.reload).to be_black_masked
      expect(Ability.new(owner).can?(:manage_attachment, part)).to be(false)
      expect(Ability.new(admin).can?(:manage_attachment, part)).to be(true)
    end
  end

  describe 'system-suggested name redaction' do
    it 'masks PDF and reply text in place and goes straight to public' do
      pdf = DocumentFixtures.text_pdf(
        title: 'Decision',
        paragraphs: ['Dear Rowan Requester, your request is granted.']
      )
      message = receive_reply(
        body: 'Dear Rowan Requester, see attached.',
        files: { 'decision.pdf' => pdf }
      )
      main_part = message.get_main_body_text_part
      pdf_part = message.foi_attachments.find { _1.filename == 'decision.pdf' }

      text_doc = make_document(main_part)
      pdf_doc = make_document(pdf_part)

      sign_in owner
      post publish_reply_hide_name_path(url_title: info_request.url_title,
                                        message_id: message.id, id: text_doc)
      expect(response).
        to redirect_to(publish_reply_published_path(
                         url_title: info_request.url_title,
                         message_id: message.id
                       ))
      expect(main_part.reload.prominence).to eq('public')
      expect(main_part.body).to include('[redacted]')
      expect(main_part.body).not_to include('Rowan Requester')
      expect(text_doc.reload.state).to eq('published')
      expect(Disclosures::ReviewSubmission.pending?(text_doc)).to be(false)

      post publish_reply_hide_name_path(url_title: info_request.url_title,
                                        message_id: message.id, id: pdf_doc)
      expect(pdf_part.reload.prominence).to eq('public')
      expect(pdf_doc.reload.state).to eq('published')
      expect(Disclosures::ReviewSubmission.pending?(pdf_doc)).to be(false)
    end

    it 'submits for admin review on hide_name when another review trigger applies' do
      message = receive_reply(
        body: 'Dear Rowan Requester, your request is granted.'
      )
      main_part = message.get_main_body_text_part
      doc = make_document(main_part, title: 'My custom requester title')

      with_setting(Disclosures, :review_requester_redactions, true) do
        sign_in owner
        post publish_reply_hide_name_path(url_title: info_request.url_title,
                                          message_id: message.id, id: doc)
      end

      expect(response).
        to redirect_to(publish_reply_published_path(
                         url_title: info_request.url_title,
                         message_id: message.id
                       ))
      expect(main_part.reload.body).not_to include('Rowan Requester')
      expect(main_part.prominence).to eq('requester_only')
      expect(doc.reload.state).to eq('draft')
      expect(Disclosures::ReviewSubmission.pending?(doc)).to be(true)
    end
  end

  describe 'requester tool edits and review setting' do
    it 'applies immediately, purges working copy, and waits for admin when review is on' do
      message = receive_reply(body: 'Dear Rowan Requester, phone 12345.')
      part = message.get_main_body_text_part
      doc = make_document(part, title: 'Reply text')

      with_setting(Disclosures, :review_requester_redactions, true) do
        sign_in owner
        post publish_reply_redact_path(url_title: info_request.url_title,
                                       message_id: message.id, id: doc),
             params: { kind: 'text_edit',
                       text: 'Dear Rowan Requester, phone [redacted].' }
      end

      part.reload
      expect(part.body).to include('[redacted]')
      expect(part.body).not_to include('12345')
      expect(part.prominence).to eq('requester_only')
      expect(Disclosures::ReviewSubmission.pending?(doc.reload)).to be(true)

      revision = AttachmentManagement::Revision.last
      expect(revision.status).to eq('applied')
      expect(revision.output).not_to be_attached
    end

    it 'goes straight to public when review_requester_redactions is off' do
      message = receive_reply(body: 'Dear Rowan Requester, phone 12345.')
      part = message.get_main_body_text_part
      doc = make_document(part, title: 'Reply text')

      with_setting(Disclosures, :review_requester_redactions, false) do
        sign_in owner
        post publish_reply_redact_path(url_title: info_request.url_title,
                                       message_id: message.id, id: doc),
             params: { kind: 'text_edit',
                       text: 'Dear Rowan Requester, phone [redacted].' }
      end

      expect(part.reload.prominence).to eq('public')
      expect(part.body).to include('[redacted]')
      expect(doc.reload.state).to eq('published')
      expect(Disclosures::ReviewSubmission.pending?(doc)).to be(false)
    end
  end

  describe 'working-copy 4-hour grace period' do
    it 'keeps open working copies inside 4 hours and purges them after 4 hours' do
      message = receive_reply(body: 'Some text to edit.')
      part = message.get_main_body_text_part

      builder = AttachmentManagement::NewRevision.new(
        part, user: owner, ability: Ability.new(owner)
      )
      revision, input = builder.build('text_edit',
                                      text: 'Some text [redacted].')
      revision.save!
      revision.output.attach(io: StringIO.new(input.b), filename: 'input',
                             content_type: 'application/octet-stream')
      AttachmentManagement::Processor.new(revision).run
      revision.reload
      expect(revision.output).to be_attached

      AttachmentManagement::Retention.new.run(now: 3.hours.from_now)
      expect(revision.reload.status).to eq('ready')
      expect(revision.output).to be_attached

      AttachmentManagement::Retention.new.run(now: 5.hours.from_now)
      expect(revision.reload.status).to eq('expired')
      expect(revision.output).not_to be_attached
    end
  end

  describe 'take down and start again' do
    it 'restores from RawEmail inside 120 days and lets the requester redact and republish' do
      message = receive_reply(
        body: 'Original text with PersonalBit and AnotherDetail.'
      )
      part = message.get_main_body_text_part
      doc = make_document(part)

      with_setting(Disclosures, :review_requester_redactions, false) do
        sign_in owner
        post publish_reply_redact_path(url_title: info_request.url_title,
                                       message_id: message.id, id: doc),
             params: {
               kind: 'text_edit',
               text: 'Original text with [redacted] and AnotherDetail.'
             }
        expect(part.reload.prominence).to eq('public')
        expect(doc.reload.state).to eq('published')
        expect(part.body).not_to include('PersonalBit')

        post publish_reply_start_again_path(url_title: info_request.url_title,
                                            message_id: message.id, id: doc)
        expect(response).to redirect_to(
          publish_reply_check_path(url_title: info_request.url_title,
                                   message_id: message.id)
        )
        expect(flash[:notice]).to include('restored from the original email')
        expect(part.reload.prominence).to eq('requester_only')
        expect(doc.reload.state).to eq('draft')
        expect(part.body).to include('PersonalBit')

        follow_redirect!
        expect(response).to have_http_status(:ok)
        expect(response.body).not_to include('Nothing from this reply')
        expect(response.body).to include('Yes, hide something', 'No, share it')

        post publish_reply_redact_path(url_title: info_request.url_title,
                                       message_id: message.id, id: doc),
             params: {
               kind: 'text_edit',
               text: 'Original text with PersonalBit and [redacted].'
             }
        expect(part.reload.prominence).to eq('public')
        expect(doc.reload.state).to eq('published')
        expect(part.body).to include('PersonalBit')
        expect(part.body).not_to include('AnotherDetail')

        message.raw_email.file.purge
        post publish_reply_start_again_path(url_title: info_request.url_title,
                                            message_id: message.id, id: doc)
        expect(flash[:notice]).
          to include('Original emails are deleted after 120 days')
        expect(part.reload.prominence).to eq('requester_only')
        expect(doc.reload.state).to eq('draft')
        expect(part.body).to include('[redacted]')
        expect(part.body).not_to include('AnotherDetail')

        follow_redirect!
        expect(response).to have_http_status(:ok)
        expect(response.body).not_to include('Nothing from this reply')

        post publish_reply_check_path(url_title: info_request.url_title,
                                      message_id: message.id),
             params: { documents: [doc.public_id] }
        expect(part.reload.prominence).to eq('public')
        expect(doc.reload.state).to eq('published')
      end
    end

    it 'reapplies black rules when restoring from RawEmail inside 120 days' do
      message = receive_reply(
        body: 'Original text with SecretWord and PersonalBit.'
      )
      part = message.get_main_body_text_part
      perform_enqueued_jobs do
        FactoryBot.create(:censor_rule, censorable: info_request,
                                        text: 'SecretWord',
                                        replacement: '[black]')
      end
      part.reload
      expect(part.body).to include('[black]')

      part.replace_file!('Original text with [black] and [redacted].')
      doc = make_document(part)
      Disclosures::Publication.new(doc, user: admin).publish!

      sign_in owner
      post publish_reply_start_again_path(url_title: info_request.url_title,
                                          message_id: message.id, id: doc)
      expect(flash[:notice]).to include('restored from the original email')
      expect(part.reload.prominence).to eq('requester_only')
      expect(doc.reload.state).to eq('draft')
      expect(part.body).to include('[black]')
      expect(part.body).to include('PersonalBit')
    end

    it 'clears attribution and review requirement inside 120 days, keeps ' \
       'them after, and rejects drafts awaiting review' do
      message = receive_reply(
        body: 'Dear Rowan Requester, detail SecretBit stays.'
      )
      part = message.get_main_body_text_part
      doc = make_document(part)

      with_setting(Disclosures, :review_requester_redactions, true) do
        sign_in owner
        post publish_reply_redact_path(url_title: info_request.url_title,
                                       message_id: message.id, id: doc),
             params: {
               kind: 'text_edit',
               text: 'Dear Rowan Requester, detail [redacted] stays.'
             }
        expect(doc.reload.state).to eq('draft')
        expect(Disclosures::ReviewSubmission.pending?(doc)).to be(true)

        post publish_reply_start_again_path(url_title: info_request.url_title,
                                            message_id: message.id, id: doc)
        expect(response).to have_http_status(:not_found)

        Disclosures::NameMask.apply!(part.reload, user: owner, document: doc,
                                                  publish: false)
        Disclosures::Publication.new(doc.reload, user: admin).publish!
        expect(Disclosures::Attribution.new(doc.reload).text).
          to eq('Redacted by the requester')

        post publish_reply_start_again_path(url_title: info_request.url_title,
                                            message_id: message.id, id: doc)
        expect(flash[:notice]).to include('restored from the original email')
        doc.reload
        expect(Disclosures::Attribution.new(doc).text).to be_nil
        expect(Disclosures::ReviewSubmission.required?(doc)).to be(false)
        expect(
          AttachmentManagement::Revision.where(
            foi_attachment_id: part.id, status: 'applied'
          )
        ).to be_empty

        post publish_reply_check_path(url_title: info_request.url_title,
                                      message_id: message.id),
             params: { documents: [doc.public_id] }
        expect(part.reload.prominence).to eq('public')
        expect(doc.reload.state).to eq('published')
        expect(Disclosures::ReviewSubmission.pending?(doc)).to be(false)
        expect(Disclosures::Attribution.new(doc).text).to be_nil

        post publish_reply_redact_path(url_title: info_request.url_title,
                                       message_id: message.id, id: doc),
             params: {
               kind: 'text_edit',
               text: 'Dear Rowan Requester, detail [redacted] stays.'
             }
        Disclosures::Publication.new(doc.reload, user: admin).publish!

        message.raw_email.file.purge
        post publish_reply_start_again_path(url_title: info_request.url_title,
                                            message_id: message.id, id: doc)
        expect(flash[:notice]).
          to include('Original emails are deleted after 120 days')
        doc.reload
        expect(Disclosures::Attribution.new(doc).text).
          to eq('Redacted by the requester')
        expect(Disclosures::ReviewSubmission.required?(doc)).to be(true)

        post publish_reply_check_path(url_title: info_request.url_title,
                                      message_id: message.id),
             params: { documents: [doc.public_id] }
        expect(part.reload.prominence).to eq('requester_only')
        expect(doc.reload.state).to eq('draft')
        expect(Disclosures::ReviewSubmission.pending?(doc)).to be(true)
      end
    end
  end

  describe 'wired UI controls' do
    it 'renders and submits the admin black_mask checkbox on box and text editors' do
      pdf = DocumentFixtures.text_pdf(title: 'Letter',
                                      paragraphs: ['Sensitive line'])
      message = receive_reply(body: 'Sensitive reply body.',
                              files: { 'letter.pdf' => pdf })
      pdf_part = message.foi_attachments.find { _1.filename == 'letter.pdf' }
      text_part = message.get_main_body_text_part

      sign_in admin
      get manage_attachment_redact_path(pdf_part)
      expect(response).to have_http_status(:ok)
      expect(response.body).to include('name="black_mask"')

      get manage_attachment_text_path(text_part)
      expect(response).to have_http_status(:ok)
      expect(response.body).to include('name="black_mask"')

      perform_enqueued_jobs do
        post manage_attachment_revisions_path(text_part),
             params: { kind: 'text_edit',
                       text: '[redacted] reply body.',
                       black_mask: '1' }
      end
      revision = AttachmentManagement::Revision.
                 where(foi_attachment_id: text_part.id).last
      expect(revision.instructions['black_mask']).to be(true)

      get manage_attachment_revision_path(text_part, revision)
      expect(response).to have_http_status(:ok)
      expect(response.body).to include('Black mask')

      post apply_manage_attachment_revision_path(text_part, revision),
           params: { reviewed: '1', reason: 'Admin black mask',
                     output_sha256: revision.output_sha256 }
      text_part.reload
      expect(text_part).to be_black_masked
      expect(text_part.manual_black_mask?).to be(true)

      with_setting(Disclosures, :requester_editing, false) do
        sign_in owner
        get manage_attachment_redact_path(pdf_part)
        expect(response).to have_http_status(:ok)
        expect(response.body).not_to include('name="black_mask"')
      end
    end

    it 'shows Hide my name and share on the check screen without persisting pages' do
      pdf = DocumentFixtures.text_pdf(
        title: 'Decision',
        paragraphs: ['Dear Rowan Requester, your request is granted.']
      )
      message = receive_reply(
        body: 'Dear Rowan Requester, see attached.',
        files: { 'decision.pdf' => pdf }
      )
      main_part = message.get_main_body_text_part
      pdf_part = message.foi_attachments.find { _1.filename == 'decision.pdf' }
      text_doc = make_document(main_part)
      pdf_doc = make_document(pdf_part)

      sign_in owner
      get publish_reply_check_path(url_title: info_request.url_title,
                                   message_id: message.id)
      expect(response).to have_http_status(:ok)
      expect(response.body).to include('Hide my name and share')
      expect(response.body).to include(
        publish_reply_hide_name_path(url_title: info_request.url_title,
                                     message_id: message.id, id: text_doc)
      )
      expect(response.body).to include(
        publish_reply_hide_name_path(url_title: info_request.url_title,
                                     message_id: message.id, id: pdf_doc)
      )
      expect(text_doc.pages.count).to eq(0)
      expect(pdf_doc.pages.count).to eq(0)

      pdf_part.update!(black_masked: true)
      get publish_reply_check_path(url_title: info_request.url_title,
                                   message_id: message.id)
      expect(response.body).not_to include(
        publish_reply_hide_name_path(url_title: info_request.url_title,
                                     message_id: message.id, id: pdf_doc)
      )
    end

    it 'renders Take down and start again on manage and published screens unless manual_black_mask' do
      message = receive_reply(body: 'Public decision text.')
      part = message.get_main_body_text_part
      doc = make_document(part)
      Disclosures::Publication.new(doc, user: owner).publish!

      start_again_url = publish_reply_start_again_path(
        url_title: info_request.url_title, message_id: message.id, id: doc
      )

      sign_in owner
      get disclosure_manage_document_path(doc)
      expect(response).to have_http_status(:ok)
      expect(response.body).to include(start_again_url)
      expect(response.body).to include('120 days')

      get publish_reply_published_path(url_title: info_request.url_title,
                                       message_id: message.id)
      expect(response).to have_http_status(:ok)
      expect(response.body).to include(start_again_url)

      message.raw_email.file.purge
      get disclosure_manage_document_path(doc)
      expect(response.body).to include(start_again_url)
      expect(response.body).
        to include('Original emails are deleted after 120 days')

      part.file_blob.update!(
        metadata: part.file_blob.metadata.merge('manual_black_mask' => true)
      )
      get disclosure_manage_document_path(doc)
      expect(response.body).not_to include(start_again_url)

      post start_again_url
      expect(doc.reload.state).to eq('published')
      expect(part.reload.prominence).to eq('public')
    end
  end

  describe 'requester format restrictions and Word-as-PDF self-service' do
    let(:docx_type) do
      'application/vnd.openxmlformats-officedocument.' \
        'wordprocessingml.document'
    end

    it 'routes CSVs, images, and text attachments to Ask admin and rejects direct POSTs' do
      png = AttachmentFixtures.image(lines: [[10, 40, 'Photo']], width: 200,
                                     height: 100)
      message = receive_reply(
        body: 'Cover note.',
        files: {
          'data.csv' => "name,value\nRowan Requester,42\n",
          'notes.txt' => "Rowan Requester secret note\n",
          'photo.png' => png
        }
      )
      csv_part = message.foi_attachments.find_by!(filename: 'data.csv')
      txt_part = message.foi_attachments.find_by!(filename: 'notes.txt')
      png_part = message.foi_attachments.find_by!(filename: 'photo.png')

      csv_doc = make_document(csv_part, title: 'Data CSV')
      txt_doc = make_document(txt_part, title: 'Notes')
      png_doc = make_document(png_part, title: 'Photo')
      args = { url_title: info_request.url_title, message_id: message.id }

      sign_in owner
      {
        csv_doc => 'Spreadsheets and CSV files can’t be edited here.',
        txt_doc => 'This type of file can’t be edited here.',
        png_doc => 'This type of file can’t be edited here.'
      }.each do |doc, expected_reason|
        get publish_reply_redact_path(**args, id: doc)
        expect(response).to have_http_status(:ok)
        expect(response.body).to include(expected_reason)
        expect(response.body).not_to include('id="document-text"')
        expect(response.body).not_to include('data-controller="box-editor"')
        expect(response.body).
          to include(publish_reply_ask_admin_path(**args, id: doc))
      end

      get publish_reply_check_path(**args)
      expect(response.body).not_to include(
        publish_reply_hide_name_path(**args, id: csv_doc)
      )
      expect(response.body).not_to include(
        publish_reply_hide_name_path(**args, id: txt_doc)
      )

      post publish_reply_redact_path(**args, id: csv_doc),
           params: { kind: 'text_edit', text: "name,value\n[redacted],42\n" }
      expect(response).
        to redirect_to(publish_reply_redact_path(**args, id: csv_doc))
      expect(csv_part.reload.body).to include('Rowan Requester')

      post publish_reply_redact_path(**args, id: txt_doc),
           params: { kind: 'text_edit', text: "[redacted] secret note\n" }
      expect(response).
        to redirect_to(publish_reply_redact_path(**args, id: txt_doc))
      expect(txt_part.reload.body).to include('Rowan Requester')

      post publish_reply_redact_path(**args, id: png_doc),
           params: { kind: 'image_redaction',
                     boxes: { '1' => [[0.1, 0.1, 0.5, 0.5]] }.to_json }
      expect(response).
        to redirect_to(publish_reply_redact_path(**args, id: png_doc))

      post publish_reply_redact_path(**args, id: csv_doc),
           params: { kind: 'office_pdf' }
      expect(response).
        to redirect_to(publish_reply_redact_path(**args, id: csv_doc))

      post publish_reply_hide_name_path(**args, id: csv_doc)
      expect(response).to redirect_to(publish_reply_check_path(**args))
      expect(csv_part.reload.body).to include('Rowan Requester')

      builder = AttachmentManagement::NewRevision.new(
        csv_part, user: owner, ability: Ability.new(owner), allow_word_pdf: true
      )
      expect do
        builder.build('text_edit', text: "name,value\n[redacted],42\n")
      end.to raise_error(AttachmentManagement::NewRevision::Invalid)
      expect do
        builder.build('office_pdf')
      end.to raise_error(AttachmentManagement::NewRevision::Invalid)
    end

    it 'converts .docx to PDF, applies Blue/Orange masks before rasterizing, queues review, and restores .docx on start_again' do
      FactoryBot.create(:censor_rule, :blue, censorable: info_request,
                                             text: 'BlueWordSecret',
                                             replacement: '[blue]')
      docx = AttachmentFixtures.docx(
        paragraphs: [
          'Keep heading.',
          'BlueWordSecret and officer@council.example',
          'ManualBoxTarget'
        ]
      )
      message = receive_reply(body: 'See attached Word file.',
                              files: { 'briefing.docx' => docx })
      part = message.foi_attachments.find_by!(filename: 'briefing.docx')
      part.update_column(:content_type, docx_type)
      read_by_analyzer(part)
      doc = make_document(part, title: 'Briefing')
      args = { url_title: info_request.url_title, message_id: message.id }

      with_setting(Disclosures, :review_requester_redactions, true) do
        sign_in owner
        get publish_reply_redact_path(**args, id: doc)
        expect(response).to have_http_status(:ok)
        expect(response.body).to include('Convert to PDF to draw boxes')

        post publish_reply_redact_path(**args, id: doc),
             params: { kind: 'office_pdf' }
        conversion = AttachmentManagement::Revision.
                     where(foi_attachment_id: part.id, kind: 'office_pdf').last
        expect(conversion).to be_ready
        expect(response).to redirect_to(
          publish_reply_redact_path(**args, id: doc, from: conversion.id)
        )
        expect(part.reload.filename).to eq('briefing.docx')

        get publish_reply_redact_path(**args, id: doc, from: conversion.id)
        expect(response).to have_http_status(:ok)
        expect(response.body).to include(
          page_manage_attachment_revision_path(part, conversion, page: 1)
        )
        get page_manage_attachment_revision_path(part, conversion, page: 1)
        expect(response).to have_http_status(:ok)
        expect(response.media_type).to eq('image/png')

        captured_source = nil
        allow(AttachmentManagement::Processor).
          to receive(:new).and_wrap_original do |m, *a, **kw|
            captured_source = kw[:source_bytes]
            m.call(*a, **kw)
          end

        post publish_reply_redact_path(**args, id: doc),
             params: {
               kind: 'pdf_redaction',
               parent_id: conversion.id,
               boxes: { '1' => [[0.0, 0.7, 0.5, 0.85]] }.to_json
             }
        expect(response).to redirect_to(publish_reply_check_path(**args))

        expect(captured_source).to be_present
        masked_text = AttachmentManagement.sandboxed(
          input: captured_source, input_name: 'masked.pdf'
        ) do |job|
          Disclosures::PDFText.pages(job.input, 1, job.scratch, job: job).
            first.text
        end
        expect(masked_text).not_to include('BlueWordSecret')
        expect(masked_text).not_to include('officer@council.example')
        expect(masked_text).to include('Keep heading.')

        part.reload
        doc.reload
        expect(part.content_type).to eq('application/pdf')
        expect(part.filename).to eq('briefing.pdf')
        expect(part.file_blob.metadata['rasterized']).to be(true)
        expect(part.prominence).to eq('requester_only')
        expect(doc.state).to eq('draft')
        expect(Disclosures::ReviewSubmission.pending?(doc)).to be(true)
        expect(conversion.reload).to be_superseded
        expect(conversion.output).not_to be_attached

        Disclosures::Publication.new(doc, user: admin).publish!
        expect(doc.reload.state).to eq('published')

        post publish_reply_start_again_path(**args, id: doc)
        expect(response).to redirect_to(publish_reply_check_path(**args))
        part.reload
        doc.reload
        expect(part.filename).to eq('briefing.docx')
        expect(part.content_type).to eq(docx_type)
        expect(part.file_blob.metadata['rasterized']).to be_nil
        expect(doc.format).to eq('document')
      end
    end
  end

  describe 'Blue rule protection on NameMask and requester email edits' do
    it 'preserves a longer Blue phrase on Hide my name and never mutates on failure' do
      FactoryBot.create(:censor_rule, :blue,
                        censorable: info_request,
                        text: 'Rowan Requester, 12 High St',
                        replacement: '[blue]')
      pdf = DocumentFixtures.text_pdf(
        title: 'Decision',
        paragraphs: [
          'Dear Rowan Requester, 12 High St, your request is granted.'
        ]
      )
      message = receive_reply(
        body: 'Dear Rowan Requester, 12 High St, see attached.',
        files: { 'decision.pdf' => pdf }
      )
      main_part = message.get_main_body_text_part
      pdf_part = message.foi_attachments.find_by!(filename: 'decision.pdf')
      main_doc = make_document(main_part, email_text: true)
      pdf_doc = make_document(pdf_part)
      args = { url_title: info_request.url_title, message_id: message.id }

      sign_in owner
      post publish_reply_hide_name_path(**args, id: main_doc)
      expect(response).to redirect_to(publish_reply_published_path(**args))
      expect(main_part.reload.prominence).to eq('public')
      expect(main_part.body).to include('[blue]')
      expect(main_part.body).not_to include('Rowan Requester')
      expect(main_part.body).not_to include('12 High St')

      post publish_reply_hide_name_path(**args, id: pdf_doc)
      expect(response).to redirect_to(publish_reply_published_path(**args))
      expect(pdf_part.reload.prominence).to eq('public')
      pdf_text = pdf_doc.reload.pages.pluck(:text).join("\n")
      expect(pdf_text).not_to include('Rowan Requester')
      expect(pdf_text).not_to include('12 High St')

      failing_msg = receive_reply(body: 'Dear Rowan Requester, fault test.')
      failing_part = failing_msg.get_main_body_text_part
      failing_doc = make_document(failing_part, email_text: true)
      original_bytes = failing_part.file.download.b

      allow(AlaveteliTextMasker).to receive(:apply_masks).
        and_raise(Regexp::TimeoutError, 'timeout')
      expect do
        Disclosures::NameMask.apply!(failing_part, user: owner,
                                                   document: failing_doc,
                                                   publish: true)
      end.to raise_error(Disclosures::Error::Refused)
      expect(failing_part.reload.file.download.b).to eq(original_bytes)
    end

    it 'requires admin review for a requester email edit matching a Blue rule even when review_requester_redactions is false' do
      FactoryBot.create(:censor_rule, :blue,
                        censorable: info_request,
                        text: 'Rowan Requester, 12 High St',
                        replacement: '[blue]')
      message = receive_reply(
        body: 'Dear Rowan Requester, 12 High St, here is our reply.'
      )
      part = message.get_main_body_text_part
      doc = make_document(part, email_text: true)
      args = { url_title: info_request.url_title, message_id: message.id }

      with_setting(Disclosures, :review_requester_redactions, false) do
        sign_in owner
        post publish_reply_redact_path(**args, id: doc),
             params: {
               kind: 'text_edit',
               text: 'Dear [redacted], 12 High St, here is our reply.'
             }
        expect(response).to redirect_to(publish_reply_check_path(**args))
        expect(part.reload.prominence).to eq('requester_only')
        expect(doc.reload.state).to eq('draft')
        expect(Disclosures::ReviewSubmission.required?(doc)).to be(true)
        expect(Disclosures::ReviewSubmission.pending?(doc)).to be(true)
      end
    end
  end
end
