require 'spec_helper'
require 'zip'

RSpec.describe 'In-place rule masking' do
  include ActiveJob::TestHelper
  include DisclosuresHelpers
  include_context 'with document OCR off'

  let(:owner) { FactoryBot.create(:user, name: 'Rowan Requester') }
  let(:admin) { FactoryBot.create(:admin_user) }
  let(:info_request) { FactoryBot.create(:info_request, user: owner) }
  let(:pdf_bytes) do
    DocumentFixtures.text_pdf(
      title: 'Council report',
      paragraphs: ['Council report mentioning SecretTerm']
    )
  end

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

  def make_public_document(attachment, title: 'Published file')
    doc = Disclosures::Document.create!(
      info_request: info_request,
      public_body: info_request.public_body,
      incoming_message: attachment.incoming_message,
      foi_attachment: attachment,
      source_kind: 'attachment',
      kind: 'released_records',
      title: title
    )
    Disclosures::Publication.new(doc, user: admin).publish!
    doc.reload
  end

  describe 'saving a black rule' do
    it 'masks private PDF, text attachment, and reply text in place without opening RawEmail' do
      message = receive_reply(
        body: 'Reply body with SecretTerm inside.',
        files: {
          'notes.txt' => 'Plain note with SecretTerm.',
          'report.pdf' => pdf_bytes
        }
      )
      main_part = message.get_main_body_text_part
      txt_part = message.foi_attachments.find { |a| a.filename == 'notes.txt' }
      pdf_part = message.foi_attachments.find { |a| a.filename == 'report.pdf' }

      expect(MailHandler::Reading).not_to receive(:of)

      rule = perform_enqueued_jobs do
        FactoryBot.create(:censor_rule, censorable: info_request,
                                        text: 'SecretTerm',
                                        replacement: '[hidden]')
      end

      [main_part, txt_part, pdf_part].each(&:reload)
      expect(main_part).to be_black_masked
      expect(main_part.body).to include('[hidden]')
      expect(main_part.body).not_to include('SecretTerm')
      expect(message.reload.get_main_body_text_unfolded).to include('[hidden]')

      expect(txt_part).to be_black_masked
      expect(txt_part.body).to include('[hidden]')
      expect(txt_part.body).not_to include('SecretTerm')

      expect(pdf_part).to be_black_masked
      expect(pdf_part.body).not_to eq(pdf_bytes)
      matched = Disclosures::RuleCheck.pdf_match?(pdf_part, pdf_part.body,
                                                  [rule])
      expect(matched).to be(false)
      expect(rule.reload.masking_finished_at).to be_present
    end

    it 'masks public PDF, text, and reply text in place, rebuilds pages, and restores public' do
      message = receive_reply(
        body: 'Public reply text with SecretTerm.',
        files: {
          'notes.txt' => 'Public notes with SecretTerm.',
          'report.pdf' => pdf_bytes
        }
      )
      main_part = message.get_main_body_text_part
      txt_part = message.foi_attachments.find { |a| a.filename == 'notes.txt' }
      pdf_part = message.foi_attachments.find { |a| a.filename == 'report.pdf' }

      docs = [main_part, txt_part, pdf_part].map { |p| make_public_document(p) }

      rule = perform_enqueued_jobs do
        FactoryBot.create(:censor_rule, censorable: info_request,
                                        text: 'SecretTerm',
                                        replacement: '[hidden]')
      end

      [main_part, txt_part, pdf_part].each do |part|
        part.reload
        expect(part.prominence).to eq('public')
        expect(part).to be_black_masked
      end
      expect(txt_part.file.download).to include('[hidden]')
      expect(main_part.file.download).to include('[hidden]')
      expect(Disclosures::RuleCheck.pdf_match?(pdf_part,
                                               pdf_part.file.download,
                                               [rule])).to be(false)

      docs.each do |doc|
        doc.reload
        expect(doc.state).to eq('published')
        texts = doc.pages.pluck(:text).join("\n")
        expect(texts).not_to include('SecretTerm')
      end
    end
  end

  describe 'saving a blue rule' do
    it 'masks public files in place and rebuilds pages while leaving private files untouched' do
      message = receive_reply(
        body: 'Private reply with BlueTerm.',
        files: {
          'private.txt' => 'Private text with BlueTerm.',
          'public.txt' => 'Public text with BlueTerm.',
          'public.pdf' => DocumentFixtures.text_pdf(
            title: 'Public PDF',
            paragraphs: ['Public PDF with BlueTerm']
          )
        }
      )
      main_part = message.get_main_body_text_part
      private_txt =
        message.foi_attachments.find { _1.filename == 'private.txt' }
      public_txt = message.foi_attachments.find { _1.filename == 'public.txt' }
      public_pdf = message.foi_attachments.find { _1.filename == 'public.pdf' }

      txt_doc = make_public_document(public_txt, title: 'Public text')
      pdf_doc = make_public_document(public_pdf, title: 'Public PDF')

      rule = perform_enqueued_jobs do
        FactoryBot.create(:censor_rule, :blue, censorable: info_request,
                                               text: 'BlueTerm',
                                               replacement: '[blue]')
      end

      expect(main_part.reload.body).to include('BlueTerm')
      expect(main_part).not_to be_black_masked
      expect(private_txt.reload.body).to include('BlueTerm')
      expect(private_txt).not_to be_black_masked

      expect(public_txt.reload.prominence).to eq('public')
      expect(public_txt).not_to be_black_masked
      expect(public_txt.file.download).to include('[blue]')
      expect(txt_doc.reload.state).to eq('published')
      expect(txt_doc.pages.pluck(:text).join).
        to include('[blue]')

      expect(public_pdf.reload.prominence).to eq('public')
      expect(public_pdf).not_to be_black_masked
      expect(Disclosures::RuleCheck.pdf_match?(public_pdf,
                                               public_pdf.file.download,
                                               [rule])).to be(false)
      expect(pdf_doc.reload.state).to eq('published')
      expect(pdf_doc.pages.pluck(:text).join).
        not_to include('BlueTerm')
    end
  end

  describe 'raster PDFs and rule deletion' do
    it 'leaves a matched raster PDF as requester_only (410) for an admin' do
      message = receive_reply(body: 'Cover note',
                              files: { 'scan.pdf' => pdf_bytes })
      pdf_part = message.foi_attachments.find { |a| a.filename == 'scan.pdf' }
      doc = make_public_document(pdf_part, title: 'Scanned PDF')
      pdf_part.file_blob.update!(
        metadata: pdf_part.file_blob.metadata.merge('rasterized' => true)
      )

      perform_enqueued_jobs do
        FactoryBot.create(:censor_rule, :blue, censorable: info_request,
                                               text: 'SecretTerm',
                                               replacement: '[blue]')
      end

      expect(pdf_part.reload.prominence).to eq('requester_only')
      expect(doc.reload.state).to eq('withdrawn')

      get disclosure_document_path(doc)
      expect(response).to have_http_status(:gone)
    end

    it 'remasks from RawEmail when a black rule is deleted within 120 days, and keeps masks after' do
      message = receive_reply(body: 'Reply with SecretTerm.')
      main_part = message.get_main_body_text_part

      rule = perform_enqueued_jobs do
        FactoryBot.create(:censor_rule, censorable: info_request,
                                        text: 'SecretTerm',
                                        replacement: '[hidden]')
      end
      expect(main_part.reload.body).to include('[hidden]')
      expect(main_part).to be_black_masked

      perform_enqueued_jobs { rule.destroy! }
      expect(main_part.reload.body).to include('SecretTerm')
      expect(main_part).not_to be_black_masked

      rule2 = perform_enqueued_jobs do
        FactoryBot.create(:censor_rule, censorable: info_request,
                                        text: 'SecretTerm',
                                        replacement: '[gone]')
      end
      expect(main_part.reload.body).to include('[gone]')

      message.raw_email.file.purge
      perform_enqueued_jobs { rule2.destroy! }
      expect(main_part.reload.body).to include('[gone]')
      expect(main_part).to be_black_masked
    end
  end

  describe 'false-positive black_masked prevention' do
    it 'leaves black_masked false and bytes unchanged on a clean PDF under non-matching black rules' do
      FactoryBot.create(:censor_rule, censorable: nil,
                                      colour: 'black',
                                      text: 'UnrelatedGlobalSecret',
                                      replacement: '[black]')
      FactoryBot.create(:censor_rule, censorable: info_request,
                                      colour: 'black',
                                      text: 'UnrelatedRequestSecret',
                                      replacement: '[black]')

      clean_pdf = DocumentFixtures.text_pdf(
        title: 'Clean report',
        paragraphs: ['Routine budget figures for 2026.']
      )
      message = receive_reply(body: 'Attached.',
                              files: { 'clean.pdf' => clean_pdf })
      pdf_part = message.foi_attachments.find { _1.filename == 'clean.pdf' }
      pdf_part.mask

      expect(pdf_part.reload).not_to be_black_masked
      expect(pdf_part.file.download.b).to eq(clean_pdf.b)

      doc = Disclosures::Creation.new(
        user: owner, attachment: pdf_part, kind: 'released_records'
      ).create!
      expect(Ability.new(owner).can?(:redact_document, doc)).to be(true)
      expect(Disclosures::RequesterPublication.problems(doc)).to be_empty
    end

    it 'leaves black_masked false on HTML with letter entities when black rules do not match' do
      FactoryBot.create(:censor_rule, censorable: info_request,
                                      colour: 'black',
                                      text: 'UnrelatedWord',
                                      replacement: '[black]')

      html = '<p>Caf&eacute; menu &amp; summary</p>'
      message = receive_reply(body: 'See HTML.',
                              files: { 'menu.html' => html })
      html_part = message.foi_attachments.find { _1.filename == 'menu.html' }
      html_part.mask

      expect(html_part.reload).not_to be_black_masked
      expect(Ability.new(owner).can?(:manage_attachment, html_part)).to be(true)

      perform_enqueued_jobs do
        FactoryBot.create(:censor_rule, censorable: info_request,
                                        colour: 'black',
                                        text: 'Café',
                                        replacement: '[black]')
      end
      expect(html_part.reload).to be_black_masked
      expect(html_part.body).to include('[black]')
    end
  end

  describe 'black rule matching a rasterized public PDF' do
    it 'hides the attachment from the requester instead of leaving it requester_only' do
      message = receive_reply(body: 'See PDF.',
                              files: { 'scan.pdf' => pdf_bytes })
      pdf_part = message.foi_attachments.find { _1.filename == 'scan.pdf' }
      doc = make_public_document(pdf_part, title: 'Scanned letter')
      pdf_part.file_blob.update!(
        metadata: pdf_part.file_blob.metadata.merge('rasterized' => true)
      )

      perform_enqueued_jobs do
        FactoryBot.create(:censor_rule, censorable: info_request,
                                        colour: 'black',
                                        text: 'SecretTerm',
                                        replacement: '[black]')
      end

      pdf_part.reload
      doc.reload
      expect(doc).not_to be_listed
      expect(pdf_part.prominence).to eq('hidden')
      expect(pdf_part).to be_black_masked
      expect(pdf_part).to be_masking_failed
      expect(Ability.new(owner).can?(:read, pdf_part)).to be(false)
    end
  end

  describe 'black rule masking fault on a public PDF' do
    it 'hides the file from the requester while keeping admin download and upload working' do
      message = receive_reply(body: 'See PDF.',
                              files: { 'report.pdf' => pdf_bytes })
      pdf_part = message.foi_attachments.find { _1.filename == 'report.pdf' }
      doc = make_public_document(pdf_part, title: 'Report')

      allow(Disclosures::Masking).to receive(:apply_rules).
        and_raise(AlaveteliTextMasker::PDFMaskingError, 'synthetic fault')

      perform_enqueued_jobs do
        FactoryBot.create(:censor_rule, censorable: info_request,
                                        colour: 'black',
                                        text: 'SecretTerm',
                                        replacement: '[black]')
      end

      pdf_part.reload
      doc.reload
      expect(doc).not_to be_listed
      expect(pdf_part.prominence).to eq('hidden')
      expect(pdf_part.prominence_reason).
        to eq('A masking rule failed on this file.')
      expect(pdf_part).to be_black_masked
      expect(pdf_part).to be_masking_failed
      expect(Ability.new(owner).can?(:read, pdf_part)).to be(false)

      sign_in(admin)
      get download_unmasked_admin_foi_attachment_path(pdf_part)
      expect(response).to have_http_status(:ok)

      get manage_attachment_path(pdf_part)
      expect(response).to have_http_status(:ok)

      safe_pdf = DocumentFixtures.text_pdf(title: 'Safe',
                                           paragraphs: ['Clean copy'])
      upload = Rack::Test::UploadedFile.new(
        StringIO.new(safe_pdf), 'application/pdf', true,
        original_filename: 'report.pdf'
      )
      perform_enqueued_jobs do
        post manage_attachment_revisions_path(pdf_part),
             params: { kind: 'upload', file: upload }
      end
      revision = AttachmentManagement::Revision.
                 where(foi_attachment_id: pdf_part.id).order(:id).last
      expect(revision).to be_ready

      post apply_manage_attachment_revision_path(pdf_part, revision),
           params: { reviewed: '1', reason: 'Admin clean upload',
                     output_sha256: revision.output_sha256 }
      pdf_part.reload
      expect(pdf_part).not_to be_masking_failed
      expect(pdf_part).to be_black_masked
      expect(pdf_part.manual_black_mask?).to be(true)
    end
  end

  describe 'stale drafts and public mask re-checks on Replacement' do
    it 'rejects a stale draft created before a black rule ran on a public file' do
      message = receive_reply(
        body: 'Cover.',
        files: { 'notes.txt' => 'Public SecretTerm text.' }
      )
      txt_part = message.foi_attachments.find { _1.filename == 'notes.txt' }
      make_public_document(txt_part, title: 'Notes')

      sign_in(admin)
      perform_enqueued_jobs do
        post manage_attachment_revisions_path(txt_part),
             params: { kind: 'text_edit',
                       text: 'Edited SecretTerm text.' }
      end
      stale_draft = AttachmentManagement::Revision.
                    where(foi_attachment_id: txt_part.id).order(:id).last
      expect(stale_draft).to be_ready

      perform_enqueued_jobs do
        FactoryBot.create(:censor_rule, censorable: info_request,
                                        colour: 'black',
                                        text: 'SecretTerm',
                                        replacement: '[black]')
      end
      txt_part.reload
      expect(txt_part.prominence).to eq('public')
      expect(txt_part.file.download).to include('[black]')
      expect(txt_part.file.download).not_to include('SecretTerm')

      post apply_manage_attachment_revision_path(txt_part, stale_draft),
           params: { reviewed: '1', reason: 'Apply stale edit',
                     output_sha256: stale_draft.output_sha256 }
      expect(response).to redirect_to(manage_attachment_path(txt_part))
      expect(flash[:error]).to include('changed since this draft')

      expect(stale_draft.reload).to be_superseded
      expect(stale_draft.output).not_to be_attached
      expect(txt_part.reload.file.download).to include('[black]')
      expect(txt_part.file.download).not_to include('SecretTerm')
    end

    it 're-applies public masks or demotes unmaskable matches when replacing a public file' do
      FactoryBot.create(:censor_rule, :blue, censorable: info_request,
                                             text: 'BlueWord',
                                             replacement: '[blue]')
      message = receive_reply(body: 'Cover.',
                              files: { 'notes.txt' => 'Initial public text.' })
      txt_part = message.foi_attachments.find { _1.filename == 'notes.txt' }
      doc = make_public_document(txt_part, title: 'Notes')

      sign_in(admin)
      perform_enqueued_jobs do
        post manage_attachment_revisions_path(txt_part),
             params: { kind: 'text_edit',
                       text: 'Updated with BlueWord and officer@example.com.' }
      end
      text_rev = AttachmentManagement::Revision.
                 where(foi_attachment_id: txt_part.id).order(:id).last
      post apply_manage_attachment_revision_path(txt_part, text_rev),
           params: { reviewed: '1', reason: 'Update text',
                     output_sha256: text_rev.output_sha256 }

      txt_part.reload
      doc.reload
      expect(txt_part.prominence).to eq('public')
      expect(doc.state).to eq('published')
      expect(txt_part.file.download).to include('[blue]')
      expect(txt_part.file.download).not_to include('BlueWord')
      expect(txt_part.file.download).not_to include('officer@example.com')

      docx_type = 'application/vnd.openxmlformats-officedocument.' \
                  'wordprocessingml.document'
      docx = AttachmentFixtures.docx(paragraphs: ['Contains BlueWord here.'])
      upload = Rack::Test::UploadedFile.new(
        StringIO.new(docx), docx_type, true, original_filename: 'notes.docx'
      )
      perform_enqueued_jobs do
        post manage_attachment_revisions_path(txt_part),
             params: { kind: 'upload', file: upload }
      end
      docx_rev = AttachmentManagement::Revision.
                 where(foi_attachment_id: txt_part.id).order(:id).last
      post apply_manage_attachment_revision_path(txt_part, docx_rev),
           params: { reviewed: '1', accept_format_change: '1',
                     reason: 'Replace with docx',
                     output_sha256: docx_rev.output_sha256 }

      txt_part.reload
      doc.reload
      expect(txt_part.prominence).to eq('requester_only')
      expect(doc.state).to eq('draft')
      expect(doc.pages).to be_empty
    end

    it 'rejects a mismatched confirmed_sha256 without changing the attachment' do
      message = receive_reply(body: 'Cover.',
                              files: { 'notes.txt' => 'Original text.' })
      txt_part = message.foi_attachments.find { _1.filename == 'notes.txt' }

      sign_in(admin)
      perform_enqueued_jobs do
        post manage_attachment_revisions_path(txt_part),
             params: { kind: 'text_edit', text: 'Changed text.' }
      end
      rev = AttachmentManagement::Revision.
            where(foi_attachment_id: txt_part.id).order(:id).last

      post apply_manage_attachment_revision_path(txt_part, rev),
           params: { reviewed: '1', reason: 'Wrong digest',
                     output_sha256: '0' * 64 }
      expect(response).
        to redirect_to(manage_attachment_revision_path(txt_part, rev))
      expect(flash[:error]).to include('different version')
      expect(rev.reload).to be_ready
      expect(txt_part.reload.file.download).to eq('Original text.')
    end

    it 'demotes a public attachment when a replacement PDF cannot be masked cleanly' do
      message = receive_reply(body: 'Cover.',
                              files: { 'report.pdf' => pdf_bytes })
      pdf_part = message.foi_attachments.find { _1.filename == 'report.pdf' }
      doc = make_public_document(pdf_part, title: 'Report')

      replacement_pdf = DocumentFixtures.text_pdf(
        title: 'Updated report',
        paragraphs: ['Updated report with officer@example.com']
      )
      upload = Rack::Test::UploadedFile.new(
        StringIO.new(replacement_pdf), 'application/pdf', true,
        original_filename: 'report.pdf'
      )
      sign_in(admin)
      perform_enqueued_jobs do
        post manage_attachment_revisions_path(pdf_part),
             params: { kind: 'upload', file: upload }
      end
      rev = AttachmentManagement::Revision.
            where(foi_attachment_id: pdf_part.id).order(:id).last
      expect(rev).to be_ready

      allow(AlaveteliTextMasker).to receive(:apply_masks).and_call_original
      allow(AlaveteliTextMasker).to receive(:apply_masks).
        with(anything, 'application/pdf', anything).
        and_raise(AlaveteliTextMasker::PDFMaskingError, 'synthetic fault')

      post apply_manage_attachment_revision_path(pdf_part, rev),
           params: { reviewed: '1', reason: 'Upload replacement pdf',
                     output_sha256: rev.output_sha256 }

      pdf_part.reload
      doc.reload
      expect(pdf_part.prominence).to eq('requester_only')
      expect(doc.state).to eq('draft')
      expect(doc.pages).to be_empty
    end

    it 'swaps to a new blob and leaves the previous public blob intact before purge' do
      message = receive_reply(body: 'Cover.',
                              files: { 'notes.txt' => 'Original public text.' })
      txt_part = message.foi_attachments.find { _1.filename == 'notes.txt' }
      make_public_document(txt_part, title: 'Notes')

      old_blob = txt_part.reload.file_blob
      old_key = old_blob.key
      old_bytes = old_blob.download

      sign_in(admin)
      perform_enqueued_jobs do
        post manage_attachment_revisions_path(txt_part),
             params: { kind: 'text_edit', text: 'Updated public text.' }
      end
      rev = AttachmentManagement::Revision.
            where(foi_attachment_id: txt_part.id).order(:id).last

      expect(old_blob).not_to receive(:upload)

      post apply_manage_attachment_revision_path(txt_part, rev),
           params: { reviewed: '1', reason: 'Replace public text',
                     output_sha256: rev.output_sha256 }

      txt_part.reload
      new_blob = txt_part.file_blob
      expect(new_blob.id).not_to eq(old_blob.id)
      expect(new_blob.key).not_to eq(old_key)
      expect(new_blob.download).to eq('Updated public text.')
      expect(old_blob.service.exist?(old_key)).to be(true)
      expect(old_blob.service.download(old_key)).to eq(old_bytes)
    end

    it 'never overwrites the live blob or exposes unmasked black/blue content publicly' do
      FactoryBot.create(:censor_rule, censorable: info_request,
                                      colour: 'black',
                                      text: 'BlackSecret',
                                      replacement: '[black]')
      FactoryBot.create(:censor_rule, :blue, censorable: info_request,
                                             text: 'BlueSecret',
                                             replacement: '[blue]')
      message = receive_reply(body: 'Cover.',
                              files: { 'notes.txt' => 'Safe public text.' })
      txt_part = message.foi_attachments.find { _1.filename == 'notes.txt' }
      doc = make_public_document(txt_part, title: 'Notes')

      old_blob = txt_part.reload.file_blob
      old_key = old_blob.key

      sign_in(admin)
      perform_enqueued_jobs do
        post manage_attachment_revisions_path(txt_part),
             params: { kind: 'text_edit',
                       text: 'Contains BlackSecret and BlueSecret.' }
      end
      rev = AttachmentManagement::Revision.
            where(foi_attachment_id: txt_part.id).order(:id).last

      observed_during_rebuild = nil
      allow_any_instance_of(Disclosures::Document).
        to receive(:rebuild_pages_from_attachment!).and_wrap_original do |m, *a|
          fresh = FoiAttachment.find(txt_part.id)
          observed_during_rebuild = {
            prominence: fresh.prominence,
            blob_key: fresh.file_blob.key,
            bytes: fresh.file.download
          }
          m.call(*a)
        end

      post apply_manage_attachment_revision_path(txt_part, rev),
           params: { reviewed: '1', reason: 'Replace with ruled terms',
                     output_sha256: rev.output_sha256 }

      expect(observed_during_rebuild[:prominence]).to eq('requester_only')
      expect(observed_during_rebuild[:blob_key]).not_to eq(old_key)
      expect(observed_during_rebuild[:bytes]).not_to include('BlackSecret')
      expect(observed_during_rebuild[:bytes]).not_to include('BlueSecret')
      expect(observed_during_rebuild[:bytes]).to include('[black]', '[blue]')

      expect(old_blob.service.download(old_key)).to eq('Safe public text.')

      txt_part.reload
      expect(txt_part.prominence).to eq('public')
      expect(txt_part).to be_black_masked
      expect(txt_part.file.download).not_to include('BlackSecret', 'BlueSecret')
      expect(doc.reload.state).to eq('published')
    end

    it 'atomically demotes a public attachment on a reviewed requester edit before post-commit work' do
      message = receive_reply(body: 'Public line one.')
      main_part = message.get_main_body_text_part
      doc = make_public_document(main_part, title: 'Reply text')
      old_blob = main_part.reload.file_blob
      old_key = old_blob.key

      builder = AttachmentManagement::NewRevision.new(
        main_part, user: owner, ability: Ability.new(owner)
      )
      rev, input = builder.build('text_edit', text: 'Public [redacted] one.')
      rev.save!
      rev.output.attach(io: StringIO.new(input.b), filename: 'input',
                        content_type: 'application/octet-stream',
                        identify: false)
      AttachmentManagement::Processor.new(rev).run
      rev.reload

      observed_before_state_update = nil
      replacement = AttachmentManagement::Replacement.new(
        rev, editor: owner, reason: 'Requester edit'
      )
      allow(replacement).to receive(:handle_publication_state!).
        and_wrap_original do |m, *args, **kwargs|
          fresh = FoiAttachment.find(main_part.id)
          observed_before_state_update = {
            prominence: fresh.prominence,
            blob_id: fresh.file_blob.id
          }
          m.call(*args, **kwargs)
        end

      with_setting(Disclosures, :review_requester_redactions, true) do
        replacement.apply!(publish: true)
      end

      expect(observed_before_state_update[:prominence]).to eq('requester_only')
      expect(observed_before_state_update[:blob_id]).not_to eq(old_blob.id)
      expect(old_blob.service.download(old_key)).to eq('Public line one.')
      expect(main_part.reload.prominence).to eq('requester_only')
      expect(doc.reload.state).to eq('draft')
    end
  end

  describe 'best-effort black masking and admin warnings on Replacement' do
    after do
      FileUtils.rm_rf(RegulatorPack.storage_dir)
    end

    def regulator_pack_entries
      token = RegulatorPack.new(info_request, user: owner).build!
      data = RegulatorPack.verify_token(token)
      path = RegulatorPack.path_for(data[:pack_id],
                                    info_request_id: info_request.id)
      zip_bytes = File.binread(path)
      entries = {}
      Zip::InputStream.open(StringIO.new(zip_bytes)) do |io|
        while (entry = io.get_next_entry)
          entries[entry.name] = io.read
        end
      end
      entries
    end

    def build_ready_upload(attachment, bytes, filename, content_type)
      upload = Rack::Test::UploadedFile.new(
        StringIO.new(bytes), content_type, true, original_filename: filename
      )
      sign_in(admin)
      perform_enqueued_jobs do
        post manage_attachment_revisions_path(attachment),
             params: { kind: 'upload', file: upload }
      end
      rev = AttachmentManagement::Revision.
            where(foi_attachment_id: attachment.id).order(:id).last
      expect(rev).to be_ready
      rev
    end

    it 'applies Black rules before swapping blobs on private admin text_edit and upload' do
      rule = FactoryBot.create(:censor_rule, censorable: info_request,
                                             colour: 'black',
                                             text: 'BlackSecret',
                                             replacement: '[black]')
      clean_pdf = DocumentFixtures.text_pdf(title: 'Initial',
                                            paragraphs: ['Clean copy'])
      message = receive_reply(
        body: 'Cover.',
        files: { 'notes.txt' => 'Clean private text.',
                 'report.pdf' => clean_pdf }
      )
      txt_part = message.foi_attachments.find { _1.filename == 'notes.txt' }
      pdf_part = message.foi_attachments.find { _1.filename == 'report.pdf' }
      expect(txt_part.prominence).to eq('requester_only')
      expect(pdf_part.prominence).to eq('requester_only')

      sign_in(admin)
      perform_enqueued_jobs do
        post manage_attachment_revisions_path(txt_part),
             params: { kind: 'text_edit',
                       text: 'Edited with BlackSecret inside.',
                       black_mask: '1' }
      end
      txt_rev = AttachmentManagement::Revision.
                where(foi_attachment_id: txt_part.id).order(:id).last
      post apply_manage_attachment_revision_path(txt_part, txt_rev),
           params: { reviewed: '1', reason: 'Admin text edit',
                     output_sha256: txt_rev.output_sha256 }

      txt_part.reload
      expect(txt_part).to be_black_masked
      expect(txt_part).not_to be_masking_failed
      expect(txt_part.file.download).to include('[black]')
      expect(txt_part.file.download).not_to include('BlackSecret')

      secret_pdf = DocumentFixtures.text_pdf(
        title: 'Updated',
        paragraphs: ['Uploaded PDF containing BlackSecret']
      )
      pdf_rev = build_ready_upload(pdf_part, secret_pdf, 'report.pdf',
                                   'application/pdf')
      post apply_manage_attachment_revision_path(pdf_part, pdf_rev),
           params: { reviewed: '1', reason: 'Admin pdf upload',
                     output_sha256: pdf_rev.output_sha256 }

      pdf_part.reload
      expect(pdf_part).to be_black_masked
      expect(pdf_part).not_to be_masking_failed
      expect(pdf_part.manual_black_mask?).to be(true)
      expect(
        Disclosures::RuleCheck.pdf_match?(pdf_part, pdf_part.file.download,
                                          [rule])
      ).to be(false)

      entries = regulator_pack_entries
      txt_entry = entries.find { |name, _| name.end_with?('notes.txt') }
      pdf_entry = entries.find { |name, _| name.end_with?('report.pdf') }
      expect(txt_entry.last).to include('[black]')
      expect(txt_entry.last).not_to include('BlackSecret')
      expect(
        Disclosures::RuleCheck.pdf_match?(pdf_part, pdf_entry.last, [rule])
      ).to be(false)
    end

    it 'allows encrypted or faulty PDF uploads under Black rules, records the fault, blocks publication, and warns the admin' do
      FactoryBot.create(:censor_rule, censorable: info_request,
                                      colour: 'black',
                                      text: 'BlackSecret',
                                      replacement: '[black]')
      clean_pdf = DocumentFixtures.text_pdf(title: 'Initial',
                                            paragraphs: ['Clean copy'])
      message = receive_reply(body: 'Cover.',
                              files: { 'report.pdf' => clean_pdf })
      pdf_part = message.foi_attachments.find { _1.filename == 'report.pdf' }
      old_blob_id = pdf_part.file_blob.id

      replacement_pdf = DocumentFixtures.text_pdf(
        title: 'Encrypted',
        paragraphs: ['Contains BlackSecret']
      )
      pdf_rev = build_ready_upload(pdf_part, replacement_pdf, 'report.pdf',
                                   'application/pdf')

      allow(PDFRedactor).to receive(:redact).
        and_raise(PDFRedactor::PasswordRequired, 'encrypted')

      post apply_manage_attachment_revision_path(pdf_part, pdf_rev),
           params: { reviewed: '1', reason: 'Upload encrypted PDF',
                     output_sha256: pdf_rev.output_sha256 }

      expect(response).to redirect_to(foi_attachment_path(pdf_part.reload))
      expect(flash[:error]).to include('automatic black masking failed')
      expect(pdf_part.file_blob.id).not_to eq(old_blob_id)
      expect(pdf_part).to be_masking_failed
      expect(pdf_part.masking_fault.first).to eq(:as_it_came)
      expect(pdf_part.unmasked_parts).to include(AlaveteliTextMasker::UNMASKED_PDF)
      expect(Ability.new(owner).can?(:read, pdf_part)).to be(true)
      expect(Ability.new(owner).can?(:create_document, pdf_part)).to be(false)

      get manage_attachment_path(pdf_part)
      expect(response).to have_http_status(:ok)
      expect(response.body).to include('Automatic masking failed on this file.')
      expect(response.body).to include(edit_admin_foi_attachment_path(pdf_part))

      allow(PDFRedactor).to receive(:redact).and_call_original
      fault_rev = build_ready_upload(pdf_part, replacement_pdf, 'report.pdf',
                                     'application/pdf')
      allow(AlaveteliTextMasker).to receive(:apply_masks).and_call_original
      allow(AlaveteliTextMasker).to receive(:apply_masks).
        with(anything, 'application/pdf', anything).
        and_raise(AlaveteliTextMasker::PDFMaskingError, 'synthetic fault')

      post apply_manage_attachment_revision_path(pdf_part, fault_rev),
           params: { reviewed: '1', reason: 'Upload broken PDF',
                     output_sha256: fault_rev.output_sha256 }

      expect(response).to redirect_to(foi_attachment_path(pdf_part.reload))
      expect(flash[:error]).to include('automatic black masking failed')
      expect(pdf_part).to be_masking_failed
      expect(pdf_part.masking_fault.last).to include('synthetic fault')
    end

    it 'allows zip and raster PDF replacements under Black rules without running OCR and warns the admin' do
      FactoryBot.create(:censor_rule, censorable: info_request,
                                      colour: 'black',
                                      text: 'BlackSecret',
                                      replacement: '[black]')
      pdf = DocumentFixtures.text_pdf(
        title: 'Notice',
        paragraphs: ['Visible BlackSecret in body']
      )
      message = receive_reply(
        body: 'Cover.',
        files: { 'notice.pdf' => pdf, 'notes.txt' => 'Original text.' }
      )
      pdf_part = message.foi_attachments.find { _1.filename == 'notice.pdf' }
      txt_part = message.foi_attachments.find { _1.filename == 'notes.txt' }

      zip_rev = build_ready_upload(txt_part, "PK\x03\x04binary".b,
                                   'archive.zip', 'application/zip')
      get manage_attachment_revision_path(txt_part, zip_rev)
      expect(response).to have_http_status(:ok)
      expect(response.body).
        to include('Automatic black masking doesn’t run on this file format.')

      post apply_manage_attachment_revision_path(txt_part, zip_rev),
           params: { reviewed: '1', accept_format_change: '1',
                     reason: 'Upload zip archive',
                     output_sha256: zip_rev.output_sha256 }

      expect(response).to redirect_to(foi_attachment_path(txt_part.reload))
      expect(flash[:notice]).
        to include('Automatic black masking doesn’t run on this file format')
      expect(txt_part).not_to be_masking_failed

      builder = AttachmentManagement::NewRevision.new(
        pdf_part, user: admin, ability: Ability.new(admin)
      )
      raster_rev, = builder.build(
        'pdf_redaction',
        boxes: { '1' => [[0.1, 0.1, 0.3, 0.3]] }.to_json
      )
      raster_rev.save!
      AttachmentManagement::Processor.new(raster_rev).run
      raster_rev.reload
      expect(raster_rev).to be_ready

      expect(Disclosures::Ocr).not_to receive(:pdf_page)
      with_setting(Disclosures, :ocr, true) do
        post apply_manage_attachment_revision_path(pdf_part, raster_rev),
             params: { reviewed: '1', reason: 'Box redaction',
                       output_sha256: raster_rev.output_sha256 }
      end

      expect(response).to redirect_to(foi_attachment_path(pdf_part.reload))
      expect(flash[:notice]).
        to include('Automatic black masking doesn’t run on this file format')
      expect(pdf_part.file_blob.metadata['rasterized']).to be(true)
    end

    it 'demotes a public replacement to requester_only and warns the admin when Black or Blue masking fails' do
      FactoryBot.create(:censor_rule, censorable: info_request,
                                      colour: 'black',
                                      text: 'BlackSecret',
                                      replacement: '[black]')
      clean_pdf = DocumentFixtures.text_pdf(title: 'Public',
                                            paragraphs: ['Clean public copy'])
      message = receive_reply(body: 'Cover.',
                              files: { 'report.pdf' => clean_pdf })
      pdf_part = message.foi_attachments.find { _1.filename == 'report.pdf' }
      doc = make_public_document(pdf_part, title: 'Report')
      old_blob_id = pdf_part.reload.file_blob.id

      secret_pdf = DocumentFixtures.text_pdf(
        title: 'Replacement',
        paragraphs: ['Contains BlackSecret']
      )
      rev = build_ready_upload(pdf_part, secret_pdf, 'report.pdf',
                               'application/pdf')

      allow(AlaveteliTextMasker).to receive(:apply_masks).and_call_original
      allow(AlaveteliTextMasker).to receive(:apply_masks).
        with(anything, 'application/pdf', anything).
        and_raise(AlaveteliTextMasker::PDFMaskingError, 'synthetic fault')

      post apply_manage_attachment_revision_path(pdf_part, rev),
           params: { reviewed: '1', reason: 'Upload broken pdf',
                     output_sha256: rev.output_sha256 }

      expect(response).to redirect_to(foi_attachment_path(pdf_part.reload))
      expect(flash[:error]).to include('taken off the public site')
      expect(flash[:error]).to include('automatic black masking failed')
      expect(pdf_part.file_blob.id).not_to eq(old_blob_id)
      expect(pdf_part.prominence).to eq('requester_only')
      expect(pdf_part).to be_masking_failed
      expect(doc.reload.state).to eq('draft')
      expect(doc.pages).to be_empty
      expect(doc).not_to be_listed
    end

    it 'still demotes a public replacement to requester_only and tells the admin when only a Blue rule fails masking' do
      FactoryBot.create(:censor_rule, :blue, censorable: info_request,
                                             text: 'BlueOnlyTerm',
                                             replacement: '[blue]')
      clean_pdf = DocumentFixtures.text_pdf(title: 'Public',
                                            paragraphs: ['Clean copy'])
      message = receive_reply(body: 'Cover.',
                              files: { 'report.pdf' => clean_pdf })
      pdf_part = message.foi_attachments.find { _1.filename == 'report.pdf' }
      doc = make_public_document(pdf_part, title: 'Report')
      old_blob_id = pdf_part.reload.file_blob.id

      replacement_pdf = DocumentFixtures.text_pdf(
        title: 'Updated',
        paragraphs: ['Contains BlueOnlyTerm']
      )
      rev = build_ready_upload(pdf_part, replacement_pdf, 'report.pdf',
                               'application/pdf')

      allow(AlaveteliTextMasker).to receive(:apply_masks).and_call_original
      allow(AlaveteliTextMasker).to receive(:apply_masks).
        with(anything, 'application/pdf', anything).
        and_raise(AlaveteliTextMasker::PDFMaskingError, 'synthetic fault')

      post apply_manage_attachment_revision_path(pdf_part, rev),
           params: { reviewed: '1', reason: 'Upload blue pdf',
                     output_sha256: rev.output_sha256 }

      pdf_part.reload
      doc.reload
      expect(flash[:notice]).to include('taken off the public site')
      expect(pdf_part.file_blob.id).not_to eq(old_blob_id)
      expect(pdf_part.prominence).to eq('requester_only')
      expect(pdf_part).not_to be_masking_failed
      expect(doc.state).to eq('draft')
      expect(doc.pages).to be_empty
    end
  end

  describe 'scanned and pictured PDFs under new censor rules' do
    def pictured_pdf(image_word:, text_line: nil)
      jpeg = AttachmentFixtures.image(
        lines: [[30, 120, image_word]],
        width: 1200,
        height: 300,
        format: 'jpg',
        point_size: 60
      )
      pixels_wide, pixels_high, components = DocumentFixtures.jpeg_size(jpeg)
      space = { 1 => '/DeviceGray', 3 => '/DeviceRGB' }.fetch(components)
      text_op = if text_line
                  "BT /F1 12 Tf 72 760 Td (#{text_line}) Tj ET "
                else
                  ''
                end
      content = "#{text_op}q 400 0 0 100 72 300 cm /Im1 Do Q"
      AttachmentFixtures.write(
        ['<< /Type /Catalog /Pages 2 0 R >>',
         '<< /Type /Pages /Kids [3 0 R] /Count 1 >>',
         '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 595 842] ' \
         '/Resources << /Font << /F1 4 0 R >> /XObject << /Im1 6 0 R >> >> ' \
         '/Contents 5 0 R >>',
         '<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>',
         "<< /Length #{content.bytesize} >>\nstream\n#{content}\nendstream",
         "<< /Type /XObject /Subtype /Image /Width #{pixels_wide} " \
         "/Height #{pixels_high} /ColorSpace #{space} /BitsPerComponent 8 " \
         "/Filter /DCTDecode /Length #{jpeg.bytesize} >>\nstream\n".b +
           jpeg.b + "\nendstream".b],
        root: 1, info: nil
      )
    end

    it 'does not republish a scanned PDF when a new blue rule matches OCR text' do
      skip 'OCR tools unavailable' unless ocr_tools?

      with_setting(Disclosures, :ocr, true) do
        scan = pictured_pdf(image_word: 'ScannedBlueWord')
        message = receive_reply(body: 'Cover.', files: { 'scan.pdf' => scan })
        pdf_part = message.foi_attachments.find { _1.filename == 'scan.pdf' }
        doc = make_public_document(pdf_part, title: 'Scanned notice')
        expect(doc.pages.pluck(:text).join).to include('ScannedBlueWord')

        perform_enqueued_jobs do
          FactoryBot.create(:censor_rule, :blue,
                            censorable: info_request.public_body,
                            text: 'ScannedBlueWord',
                            replacement: '[blue]')
        end

        pdf_part.reload
        doc.reload
        expect(pdf_part.prominence).to eq('requester_only')
        expect(doc.state).to eq('withdrawn')
        expect(doc).not_to be_listed
        expect(doc.pages).to be_empty
      end
    end

    it 'hides a scanned PDF when a new black rule matches OCR text' do
      skip 'OCR tools unavailable' unless ocr_tools?

      with_setting(Disclosures, :ocr, true) do
        scan = pictured_pdf(image_word: 'ScannedBlackWord')
        message = receive_reply(body: 'Cover.', files: { 'scan.pdf' => scan })
        pdf_part = message.foi_attachments.find { _1.filename == 'scan.pdf' }
        doc = make_public_document(pdf_part, title: 'Scanned notice')

        perform_enqueued_jobs do
          FactoryBot.create(:censor_rule,
                            censorable: info_request.public_body,
                            colour: 'black',
                            text: 'ScannedBlackWord',
                            replacement: '[black]')
        end

        pdf_part.reload
        doc.reload
        expect(pdf_part.prominence).to eq('hidden')
        expect(pdf_part).to be_black_masked
        expect(pdf_part).to be_masking_failed
        expect(doc.state).to eq('withdrawn')
        expect(doc).not_to be_listed
        expect(doc.pages).to be_empty
      end
    end

    it 'does not republish a hybrid PDF when text masks but a picture still matches OCR' do
      skip 'OCR tools unavailable' unless ocr_tools?

      with_setting(Disclosures, :ocr, true) do
        hybrid = pictured_pdf(
          image_word: 'HybridSecretWord',
          text_line: 'Council reply mentioning HybridSecretWord in text.'
        )
        message = receive_reply(body: 'Cover.',
                                files: { 'hybrid.pdf' => hybrid })
        pdf_part = message.foi_attachments.find { _1.filename == 'hybrid.pdf' }
        doc = make_public_document(pdf_part, title: 'Hybrid notice')

        rule = FactoryBot.create(:censor_rule, :blue,
                                 censorable: info_request,
                                 text: 'HybridSecretWord',
                                 replacement: '[blue]')
        result = Disclosures::RuleRemask.apply_to_attachment!(pdf_part.reload,
                                                              rule)

        expect(result).to eq(:left_private)
        expect(pdf_part.reload.prominence).to eq('requester_only')
        expect(doc.reload.state).to eq('withdrawn')
        expect(doc).not_to be_listed
        expect(doc.pages).to be_empty
      end
    end

    it 'hides a hybrid PDF under a black rule when a picture still matches OCR' do
      skip 'OCR tools unavailable' unless ocr_tools?

      with_setting(Disclosures, :ocr, true) do
        hybrid = pictured_pdf(
          image_word: 'HybridBlackWord',
          text_line: 'Council reply mentioning HybridBlackWord in text.'
        )
        message = receive_reply(body: 'Cover.',
                                files: { 'hybrid.pdf' => hybrid })
        pdf_part = message.foi_attachments.find { _1.filename == 'hybrid.pdf' }
        doc = make_public_document(pdf_part, title: 'Hybrid notice')

        rule = FactoryBot.create(:censor_rule, censorable: info_request,
                                               colour: 'black',
                                               text: 'HybridBlackWord',
                                               replacement: '[black]')
        result = Disclosures::RuleRemask.apply_to_attachment!(pdf_part.reload,
                                                              rule)

        expect(result).to eq(:left_private)
        expect(pdf_part.reload.prominence).to eq('hidden')
        expect(pdf_part).to be_black_masked
        expect(pdf_part).to be_masking_failed
        expect(doc.reload.state).to eq('withdrawn')
        expect(doc.pages).to be_empty
      end
    end
  end
end
