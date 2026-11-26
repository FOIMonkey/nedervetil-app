require 'spec_helper'
require 'open3'
require 'tmpdir'

RSpec.describe 'Legacy Office (.doc and .xls) publishing and conversion notes' do
  include ActiveJob::TestHelper
  include DisclosuresHelpers
  include_context 'with document OCR off'
  include_context 'with a separate Manage workspace'

  let(:owner) { FactoryBot.create(:user, name: 'Rowan Requester') }
  let(:admin) { FactoryBot.create(:admin_user) }
  let(:info_request) do
    FactoryBot.create(:info_request, user: owner, title: 'Library budget 2026')
  end
  let(:excel_fixtures) { Rails.root.join('gems/excel_analyzer/spec/fixtures') }
  let(:docx_type) do
    'application/vnd.openxmlformats-officedocument.wordprocessingml.document'
  end

  def convert_with_soffice(bytes, from_ext:, to_ext:)
    Dir.mktmpdir('legacy-fixture') do |dir|
      src = File.join(dir, "source.#{from_ext}")
      File.binwrite(src, bytes)
      _out, err, status = Open3.capture3(
        'soffice', '--headless', '--norestore', '--nolockcheck', '--nodefault',
        "-env:UserInstallation=file://#{dir}/profile",
        '--convert-to', to_ext, '--outdir', dir, src
      )
      converted = File.join(dir, "source.#{to_ext}")
      unless status.success? && File.exist?(converted)
        raise "soffice #{from_ext}->#{to_ext} failed: #{err}"
      end

      File.binread(converted)
    end
  end

  def build_doc(paragraphs:)
    docx = DocumentFixtures.docx(paragraphs: paragraphs)
    convert_with_soffice(docx, from_ext: 'docx', to_ext: 'doc')
  end

  def build_xls(sheets:)
    xlsx = DocumentFixtures.xlsx(sheets: sheets)
    convert_with_soffice(xlsx, from_ext: 'xlsx', to_ext: 'xls')
  end

  def ledger_entries(html_body)
    doc = Nokogiri::HTML(html_body)
    doc.css('.document-ledger > div').to_h do |row|
      [row.at_css('dt')&.text&.squish, row.at_css('dd')&.text&.squish]
    end
  end

  describe '.xls publishing' do
    it 'publishes a clean .xls directly as a spreadsheet with sheet previews' do
      xls_bytes = File.binread(excel_fixtures.join('data.xls'))
      doc = delivered_document(info_request, 'budget.xls',
                               'application/vnd.ms-excel', xls_bytes)

      Disclosures::Publication.new(doc, user: owner).publish!
      doc.reload
      attachment = doc.foi_attachment.reload

      expect(doc).to be_listed
      expect(doc.format).to eq('spreadsheet')
      expect(attachment.filename).to eq('budget.xls')
      expect(attachment.content_type).to eq('application/vnd.ms-excel')
      expect(doc.pages.count).to be >= 1
      expect(doc.pages.first.kind).to eq('sheet')

      get disclosure_document_path(doc)
      expect(response).to have_http_status(:ok)
      expect(response.body).to include('Download XLS')
      expect(ledger_entries(response.body)).not_to have_key('Original file')
    end

    it 'blocks a requester from publishing an .xls with a hidden sheet' do
      suspect_xls = File.binread(excel_fixtures.join('suspect.xls'))
      doc = delivered_document(info_request, 'suspect.xls',
                               'application/vnd.ms-excel', suspect_xls)

      expect {
        Disclosures::Publication.new(doc, user: owner).publish!
      }.to raise_error(Disclosures::Error::Refused, /hidden content/i)

      expect(doc.reload).not_to be_listed
      expect(doc.foi_attachment.reload.prominence).to eq('requester_only')
    end

    it 'catches censor rules in .xls on publish, RuleCheck, and RuleRemask' do
      xls_bytes = build_xls(
        sheets: [{ name: 'Spend',
                   rows: [%w[Item Code], %w[Books SecretXlsCode]] }]
      )
      doc = delivered_document(info_request, 'spend.xls',
                               'application/vnd.ms-excel', xls_bytes)

      rule = FactoryBot.create(:censor_rule, :blue,
                               censorable: info_request,
                               text: 'SecretXlsCode',
                               replacement: '[redacted]')
      expect(
        Disclosures::RuleCheck.match?(doc, xls_bytes, rules: [rule],
                                                      format: 'spreadsheet')
      ).to be(true)

      expect {
        Disclosures::Publication.new(doc, user: owner).publish!
      }.to raise_error(Disclosures::Error::Refused, /privacy check/i)

      rule.destroy!
      Disclosures::Publication.new(doc, user: owner).publish!
      expect(doc.reload).to be_listed

      perform_enqueued_jobs do
        FactoryBot.create(:censor_rule, :blue,
                          censorable: info_request,
                          text: 'SecretXlsCode',
                          replacement: '[redacted]')
      end

      expect(doc.reload).not_to be_listed
      expect(doc.state).to eq('withdrawn')
      expect(doc.foi_attachment.reload.prominence).to eq('requester_only')
    end

    it 'keeps .xls admin-only on the requester redact screen' do
      xls_bytes = File.binread(excel_fixtures.join('data.xls'))
      doc = delivered_document(info_request, 'budget.xls',
                               'application/vnd.ms-excel', xls_bytes)
      args = { url_title: info_request.url_title,
               message_id: doc.incoming_message_id }

      sign_in(owner)
      get publish_reply_redact_path(**args, id: doc)
      expect(response).to have_http_status(:ok)
      expect(response.body).
        to include('Spreadsheets and CSV files can’t be edited here.')
    end
  end

  describe '.doc auto-conversion on publish' do
    it 'notes PDF conversion on check/read, converts and masks on publish, ' \
       'shows the Original file note, and restores .doc on start_again' do
      doc_bytes = build_doc(
        paragraphs: [
          'Library opening hours summary.',
          'BlackSecretTerm and BlueSecretTerm and officer@council.example'
        ]
      )
      FactoryBot.create(:censor_rule, censorable: info_request,
                                      colour: 'black',
                                      text: 'BlackSecretTerm',
                                      replacement: '[black]')
      FactoryBot.create(:censor_rule, :blue, censorable: info_request,
                                             text: 'BlueSecretTerm',
                                             replacement: '[blue]')

      doc = delivered_document(info_request, 'minutes.doc',
                               'application/vnd.ms-word', doc_bytes)
      args = { url_title: info_request.url_title,
               message_id: doc.incoming_message_id }

      sign_in(owner)
      get publish_reply_check_path(**args)
      expect(response).to have_http_status(:ok)
      expect(response.body).to include(
        'This Word (.doc) file will be converted to a PDF when you share it'
      )

      get publish_reply_read_path(**args, id: doc)
      expect(response).to have_http_status(:ok)
      expect(response.body).to include(
        'This Word (.doc) file will be converted to a PDF when you share it'
      )

      Disclosures::Publication.new(doc, user: owner).publish!
      doc.reload
      attachment = doc.foi_attachment.reload

      expect(doc).to be_listed
      expect(doc.format).to eq('pdf')
      expect(attachment.filename).to eq('minutes.pdf')
      expect(attachment.content_type).to eq('application/pdf')
      expect(attachment.file.download.byteslice(0, 5)).to eq('%PDF-')
      expect(attachment.file_blob.metadata).to include(
        'converted_from_extension' => '.doc',
        'converted_from_content_type' => 'application/vnd.ms-word'
      )

      page_text = doc.pages.pluck(:text).join("\n")
      expect(page_text).to include('Library opening hours summary')
      expect(page_text).not_to include('BlackSecretTerm')
      expect(page_text).not_to include('BlueSecretTerm')
      expect(page_text).not_to include('officer@council.example')

      get disclosure_document_path(doc)
      expect(response).to have_http_status(:ok)
      expect(response.body).to include('Download PDF')
      expect(ledger_entries(response.body)['Original file']).
        to eq('Word document (.doc), converted to PDF')

      outcome = doc.take_down_and_start_again!(by: owner)
      expect(outcome).to eq(:restored)
      doc.reload
      attachment.reload

      expect(doc.state).to eq('draft')
      expect(doc.format).to eq('document')
      expect(attachment.filename).to eq('minutes.doc')
      expect(attachment.content_type).to eq('application/vnd.ms-word')
      expect(Disclosures::Formats.ole2?(attachment.file.download)).to be(true)
      expect(attachment.file_blob.metadata).
        not_to have_key('converted_from_extension')
      expect(attachment.file_blob.metadata).
        not_to have_key('converted_from_content_type')
    end

    it 'rolls back cleanly to .doc and deletes orphan PDF blobs on refusal' do
      doc_bytes = File.binread(Rails.root.join('spec/fixtures/files/lorem.doc'))
      doc = delivered_document(info_request, 'lorem.doc',
                               'application/vnd.ms-word', doc_bytes)
      attachment = doc.foi_attachment
      original_blob = attachment.file_blob
      uploaded_keys = []

      allow(ActiveStorage::Blob).to receive(:create_and_upload!).
        and_wrap_original do |method, **kwargs|
          blob = method.call(**kwargs)
          uploaded_keys << blob.key
          blob
        end
      allow(Disclosures::Masking).to receive(:apply_public_masks!).
        and_raise(Disclosures::Error::Refused, 'Synthetic safety stop')

      expect {
        Disclosures::Publication.new(doc, user: owner).publish!
      }.to raise_error(Disclosures::Error::Refused, 'Synthetic safety stop')

      doc.reload
      attachment.reload
      expect(doc.state).to eq('draft')
      expect(doc.format).to eq('document')
      expect(attachment.filename).to eq('lorem.doc')
      expect(attachment.content_type).to eq('application/vnd.ms-word')
      expect(attachment.file_blob.id).to eq(original_blob.id)
      expect(Disclosures::Formats.ole2?(attachment.file.download)).to be(true)
      expect(uploaded_keys).not_to be_empty
      uploaded_keys.each do |key|
        expect(original_blob.service.exist?(key)).to be(false)
      end
    end

    it 'refuses cleanly when LibreOffice is unavailable for .doc or .xls' do
      doc_bytes = File.binread(Rails.root.join('spec/fixtures/files/lorem.doc'))
      xls_bytes = File.binread(excel_fixtures.join('data.xls'))
      doc = delivered_document(info_request, 'lorem.doc',
                               'application/vnd.ms-word', doc_bytes)
      rule = FactoryBot.create(:censor_rule, :blue,
                               censorable: info_request,
                               text: 'AnyWord',
                               replacement: '[redacted]')

      allow(AttachmentManagement::Command).to receive(:available?).
        with('soffice').and_return(false)

      expect {
        Disclosures::Publication.new(doc, user: owner).publish!
      }.to raise_error(Disclosures::Error::Refused, /LibreOffice/)
      expect(doc.reload.state).to eq('draft')
      expect(doc.foi_attachment.reload.filename).to eq('lorem.doc')

      expect {
        Disclosures::RuleCheck.match?(doc, xls_bytes, rules: [rule],
                                                      format: 'spreadsheet')
      }.to raise_error(Disclosures::RuleCheck::Unreadable)
    end

    it 'cleans up converted .doc PDF blobs when a later document in publish_all! fails' do
      doc_bytes = File.binread(Rails.root.join('spec/fixtures/files/lorem.doc'))
      message = AttachmentFixtures.deliver(
        info_request,
        [['first.doc', 'application/vnd.ms-word', doc_bytes],
         ['second.txt', 'text/plain', 'Plain text reply.']]
      )
      first_att = file_in(message, 'first.doc')
      second_att = file_in(message, 'second.txt')
      doc1 = document_from_attachment(first_att, by: owner)
      doc2 = document_from_attachment(second_att, by: owner)
      doc2.update_columns(erased_at: Time.current)
      original_blob = first_att.file_blob

      uploaded_keys = []
      allow(ActiveStorage::Blob).to receive(:create_and_upload!).
        and_wrap_original do |method, **kwargs|
          blob = method.call(**kwargs)
          uploaded_keys << blob.key
          blob
        end

      expect {
        Disclosures::RequesterPublication.publish_all!([doc1, doc2],
                                                       user: owner)
      }.to raise_error(Disclosures::Error::Refused)

      doc1.reload
      first_att.reload
      expect(doc1.state).to eq('draft')
      expect(doc1.format).to eq('document')
      expect(first_att.filename).to eq('first.doc')
      expect(first_att.content_type).to eq('application/vnd.ms-word')
      expect(first_att.file_blob.id).to eq(original_blob.id)
      expect(Disclosures::Formats.ole2?(first_att.file.download)).to be(true)
      expect(uploaded_keys).not_to be_empty
      uploaded_keys.each do |key|
        expect(original_blob.service.exist?(key)).to be(false)
      end
    end
  end

  describe 'original-filetype note across Word-to-PDF and admin conversions' do
    it 'records .doc on requester Word-to-PDF redaction and preserves it ' \
       'across later PDF redactions' do
      doc_bytes = build_doc(paragraphs: ['Council minutes line one.'])
      doc = delivered_document(info_request, 'council.doc',
                               'application/vnd.ms-word', doc_bytes)
      part = doc.foi_attachment
      args = { url_title: info_request.url_title,
               message_id: doc.incoming_message_id }

      with_setting(Disclosures, :review_requester_redactions, false) do
        sign_in(owner)
        post publish_reply_redact_path(**args, id: doc),
             params: { kind: 'office_pdf' }
        conversion = AttachmentManagement::Revision.
                     where(foi_attachment_id: part.id, kind: 'office_pdf').last
        expect(conversion).to be_ready

        post publish_reply_redact_path(**args, id: doc),
             params: { kind: 'pdf_redaction',
                       parent_id: conversion.id,
                       boxes: { '1' => [[0.1, 0.1, 0.4, 0.2]] }.to_json }
        expect(doc.reload).to be_listed
        expect(part.reload.filename).to eq('council.pdf')
        expect(part.file_blob.metadata).to include(
          'converted_from_extension' => '.doc',
          'converted_from_content_type' => 'application/vnd.ms-word'
        )

        get disclosure_document_path(doc)
        expect(response).to have_http_status(:ok)
        expect(ledger_entries(response.body)['Original file']).
          to eq('Word document (.doc), converted to PDF')

        post publish_reply_redact_path(**args, id: doc),
             params: { kind: 'pdf_redaction',
                       boxes: { '1' => [[0.1, 0.3, 0.4, 0.4]] }.to_json }
        expect(doc.reload).to be_listed
        expect(part.reload.file_blob.metadata).to include(
          'converted_from_extension' => '.doc',
          'converted_from_content_type' => 'application/vnd.ms-word'
        )

        get disclosure_document_path(doc)
        expect(ledger_entries(response.body)['Original file']).
          to eq('Word document (.doc), converted to PDF')
      end
    end

    it 'records .docx on requester Word-to-PDF redaction' do
      docx_bytes = DocumentFixtures.docx(paragraphs: ['Briefing paragraph.'])
      doc = delivered_document(info_request, 'briefing.docx',
                               docx_type, docx_bytes)
      part = doc.foi_attachment
      args = { url_title: info_request.url_title,
               message_id: doc.incoming_message_id }

      with_setting(Disclosures, :review_requester_redactions, false) do
        sign_in(owner)
        post publish_reply_redact_path(**args, id: doc),
             params: { kind: 'office_pdf' }
        conversion = AttachmentManagement::Revision.
                     where(foi_attachment_id: part.id, kind: 'office_pdf').last
        expect(conversion).to be_ready

        post publish_reply_redact_path(**args, id: doc),
             params: { kind: 'pdf_redaction',
                       parent_id: conversion.id,
                       boxes: { '1' => [[0.1, 0.1, 0.4, 0.2]] }.to_json }
        expect(doc.reload).to be_listed

        get disclosure_document_path(doc)
        expect(ledger_entries(response.body)['Original file']).
          to eq('Word document (.docx), converted to PDF')
      end
    end

    it 'records original format when an admin converts a file via office_pdf' do
      xls_bytes = File.binread(excel_fixtures.join('data.xls'))
      doc = delivered_document(info_request, 'figures.xls',
                               'application/vnd.ms-excel', xls_bytes)
      part = doc.foi_attachment

      sign_in(admin)
      perform_enqueued_jobs do
        post manage_attachment_revisions_path(part),
             params: { kind: 'office_pdf' }
      end
      revision = AttachmentManagement::Revision.
                 where(foi_attachment_id: part.id, kind: 'office_pdf').last
      expect(revision).to be_ready

      post apply_manage_attachment_revision_path(part, revision),
           params: { reviewed: '1',
                     accept_format_change: '1',
                     reason: 'Convert spreadsheet to PDF',
                     output_sha256: revision.output_sha256 }
      part.reload
      expect(part.content_type).to eq('application/pdf')
      expect(part.file_blob.metadata).to include(
        'converted_from_extension' => '.xls',
        'converted_from_content_type' => 'application/vnd.ms-excel'
      )

      Disclosures::Publication.new(doc.reload, user: admin).publish!
      expect(doc.reload).to be_listed

      get disclosure_document_path(doc)
      expect(response).to have_http_status(:ok)
      expect(ledger_entries(response.body)['Original file']).
        to eq('Excel spreadsheet (.xls), converted to PDF')
    end

    it 'records original format on a format-changing admin upload only' do
      docx_bytes = DocumentFixtures.docx(paragraphs: ['Original Word copy.'])
      doc = delivered_document(info_request, 'policy.docx',
                               docx_type, docx_bytes)
      part = doc.foi_attachment
      safe_pdf = DocumentFixtures.text_pdf(title: 'Policy PDF',
                                           paragraphs: ['Clean PDF copy'])
      upload = Rack::Test::UploadedFile.new(
        StringIO.new(safe_pdf), 'application/pdf', true,
        original_filename: 'policy.pdf'
      )

      sign_in(admin)
      perform_enqueued_jobs do
        post manage_attachment_revisions_path(part),
             params: { kind: 'upload', file: upload }
      end
      revision = AttachmentManagement::Revision.
                 where(foi_attachment_id: part.id, kind: 'upload').last
      expect(revision).to be_ready

      post apply_manage_attachment_revision_path(part, revision),
           params: { reviewed: '1',
                     accept_format_change: '1',
                     reason: 'Replace Word file with clean PDF',
                     output_sha256: revision.output_sha256 }

      Disclosures::Publication.new(doc.reload, user: admin).publish!
      get disclosure_document_path(doc.reload)
      expect(response).to have_http_status(:ok)
      expect(ledger_entries(response.body)['Original file']).
        to eq('Word document (.docx), converted to PDF')

      pdf_doc = delivered_document(info_request, 'notice.pdf',
                                   'application/pdf', safe_pdf)
      pdf_part = pdf_doc.foi_attachment
      second_pdf = DocumentFixtures.text_pdf(title: 'Updated PDF',
                                             paragraphs: ['Updated copy'])
      same_upload = Rack::Test::UploadedFile.new(
        StringIO.new(second_pdf), 'application/pdf', true,
        original_filename: 'notice.pdf'
      )
      perform_enqueued_jobs do
        post manage_attachment_revisions_path(pdf_part),
             params: { kind: 'upload', file: same_upload }
      end
      pdf_rev = AttachmentManagement::Revision.
                where(foi_attachment_id: pdf_part.id, kind: 'upload').last
      post apply_manage_attachment_revision_path(pdf_part, pdf_rev),
           params: { reviewed: '1',
                     reason: 'Replace PDF with PDF',
                     output_sha256: pdf_rev.output_sha256 }
      expect(pdf_part.reload.file_blob.metadata).
        not_to have_key('converted_from_extension')
    end
  end
end
