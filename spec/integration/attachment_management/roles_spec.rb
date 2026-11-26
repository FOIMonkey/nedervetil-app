require 'spec_helper'

RSpec.describe 'Attachment management roles' do
  # Requesters reach the thread editor's screens when the publish flow is off.
  include_context 'with the publish flow off'
  include ActiveJob::TestHelper
  include DisclosuresHelpers

  include_context 'with a separate Manage workspace'

  around do |example|
    keeping_settings(AttachmentManagement, :requester_access) { example.run }
  end

  before do
    allow(Rails.application.config).
      to receive(:consider_all_requests_local).and_return(false)
  end

  let(:owner) { FactoryBot.create(:user) }
  let(:admin) { FactoryBot.create(:admin_user) }
  let(:info_request) { FactoryBot.create(:info_request, user: owner) }
  let(:text) do
    "Name: Alice Synthetic\nPhone: 01632 960123\n" \
      "Outcome: the complaint was upheld.\n"
  end
  let(:attachment_text) { "Attachment copy.\n#{text}" }
  let(:message) do
    AttachmentFixtures.deliver(
      info_request,
      [['public.txt', 'text/plain', attachment_text],
       ['letter.pdf', 'application/pdf',
        AttachmentFixtures.pdf(
          pages: [AttachmentFixtures.letter_page(secret: 'Alice Synthetic')]
        )],
       ['briefing.docx',
        'application/vnd.openxmlformats-officedocument.' \
        'wordprocessingml.document',
        AttachmentFixtures.docx(paragraphs: ['Briefing'])]],
      text: text
    )
  end
  let(:body_part) { message.get_main_body_text_part }
  let(:notes) do
    message.get_attachments_for_display.find { |a| a.filename == 'public.txt' }
  end
  let(:pdf) do
    message.get_attachments_for_display.find { |a| a.filename == 'letter.pdf' }
  end
  # Read by the analyzer, as Word files wait for its scan for embedded
  # spreadsheets before the requester can use them.
  let(:docx) do
    message.get_attachments_for_display.
      find { |a| a.filename == 'briefing.docx' }.
      tap { |part| read_by_analyzer(part) }
  end

  def version(record)
    Digest::SHA256.hexdigest(FoiAttachment.find(record.id).body.to_s)
  end

  def draft!(record, **params)
    post manage_attachment_revisions_path(record),
         params: { source_sha256: version(record), **params }
    perform_enqueued_jobs(only: AttachmentManagement::ProcessJob)
    AttachmentManagement::Revision.where(foi_attachment_id: record.id).
      order(:id).last&.reload
  end

  def confirm!(record, draft, **params)
    post apply_manage_attachment_revision_path(record, draft),
         params: { reviewed: '1', reason: 'Synthetic role check',
                   output_sha256: draft.output_sha256, **params }
  end

  def upload(bytes, type, name)
    Rack::Test::UploadedFile.new(StringIO.new(bytes), type, true,
                                 original_filename: name)
  end

  describe AttachmentManagement::TextRedaction do
    let(:current) do
      "Dear Ms Synthetic,\nCall Alice on 01632 960123.\nRegards\n"
    end

    def ok?(edited)
      described_class.check!(current, edited)
    rescue described_class::Rejected
      false
    end

    it 'accepts runs of the text replaced with [redacted], anywhere and in any case' do
      expect(ok?("Dear Ms [redacted],\n" \
                 "Call [REDACTED] on [redacted].\nRegards\n")).to be true
      expect(ok?("[redacted]Call Alice on 01632 960123.\nRegards\n")).to be true
      expect(ok?("Dear Ms Synthetic,\n[Redacted]")).to be true
      expect(ok?("Dear Ms [redacted] on 01632 960123.\nRegards\n")).to be true
      expect(ok?("[redacted][redacted]")).to be true
    end

    it 'refuses added, reworded or silently deleted words, and markers that remove nothing' do
      expect(ok?("Dear Ms Synthetic,\n" \
                 "Call Alice on 01632 960123.\nRegards\nForged line\n")).
        to be false
      expect(ok?("Dear Ms Synthetic,\nCall Bob on 01632 960123.\nRegards\n")).
        to be false
      expect(ok?("Dear Ms Synthetic,\nCall on 01632 960123.\nRegards\n")).
        to be false
      expect(ok?("Dear Ms Synthetic,\n" \
                 "Call Alice [redacted]on 01632 960123.\nRegards\n")).
        to be false
      expect(ok?("Dear Ms Synthetic,\n" \
                 "Call [name] on 01632 960123.\nRegards\n")).to be false
      expect(ok?("Dear Ms [redacted],\n" \
                 "Call Alice on 01632 960123 today.\nRegards\n")).to be false
    end
  end

  describe 'a requester (the default: redact only)' do
    before { sign_in(owner) }

    it 'is offered no text redaction, upload or conversion' do
      get manage_attachment_path(body_part)
      page = Nokogiri::HTML(response.body)
      expect(page.text).not_to include('Redact the text')
      expect(page.css('input[name="kind"][value="upload"], ' \
                      'input[name="kind"][value="office_pdf"]')).to be_empty

      get manage_attachment_path(notes)
      expect(Nokogiri::HTML(response.body).text).
        not_to include('Redact the text')

      get manage_attachment_path(docx)
      page = Nokogiri::HTML(response.body)
      expect(page.text).to include('Only an admin can replace this file')
      expect(page.css('input[name="kind"]')).to be_empty
    end

    it 'can’t open the text editor or save a text draft' do
      get manage_attachment_text_path(body_part)
      expect(response).to have_http_status(:not_found)
      draft!(body_part,
             kind: 'text_edit',
             text: "Name: [redacted]\nPhone: [redacted]\n" \
                   "Outcome: the complaint was upheld.\n")
      expect(flash[:error]).to include('Only an admin can edit')
      expect(AttachmentManagement::Revision.count).to eq(0)
    end

    it 'can’t upload, convert, or draw on a conversion' do
      post manage_attachment_revisions_path(notes),
           params: {
             kind: 'upload',
             file: upload(
               AttachmentFixtures.pdf(
                 pages: [AttachmentFixtures.letter_page(secret: 'Other')]
               ),
               'application/pdf', 'x.pdf'
             )
           }
      expect(flash[:error]).to include('Only an admin can upload')
      post manage_attachment_revisions_path(docx),
           params: { kind: 'office_pdf' }
      expect(flash[:error]).to include('Only an admin can convert')
      expect(AttachmentManagement::Revision.count).to eq(0)

      sign_in(admin)
      conversion = draft!(docx, kind: 'office_pdf')
      sign_in(owner)
      get manage_attachment_redact_path(docx, from: conversion.id)
      expect(response).to have_http_status(:not_found)
      post manage_attachment_revisions_path(docx),
           params: { kind: 'pdf_redaction', parent_id: conversion.id,
                     source_sha256: version(docx),
                     boxes: { '1' => [[0, 0, 1, 0.5]] }.to_json }
      expect(AttachmentManagement::Revision.where(kind: 'pdf_redaction')).
        to be_empty
    end

    it 'redacts a PDF with boxes and confirms it' do
      draft = draft!(
        pdf,
        kind: 'pdf_redaction',
        boxes: { '1' => [AttachmentFixtures.letter_secret_box] }.to_json
      )
      confirm!(pdf, draft)
      expect(draft.reload).to be_applied
    end
  end

  describe 'drafts' do
    it 'keeps an admin’s unconfirmed upload from the requester (the review’s reproduction)' do
      sign_in(admin)
      draft = draft!(notes,
                     kind: 'upload',
                     file: upload("Admin-only draft content\n", 'text/plain',
                                  'private-draft.txt'))
      expect(draft).to be_ready

      sign_in(owner)
      get file_manage_attachment_revision_path(notes, draft)
      expect(response).to have_http_status(:not_found)
      expect(response.body).not_to include('Admin-only draft content')
      [[:get, manage_attachment_revision_path(notes, draft)],
       [:get, page_manage_attachment_revision_path(notes, draft, page: 1)],
       [:post, apply_manage_attachment_revision_path(notes, draft)],
       [:post, discard_manage_attachment_revision_path(notes, draft)]].
        each do |verb, path|
          send(verb, path, params: { reviewed: '1', reason: 'x',
                                     output_sha256: draft.output_sha256 })
          expect(response).to have_http_status(:not_found), "#{verb} #{path}"
        end
      get manage_attachment_path(notes)
      expect(Nokogiri::HTML(response.body).
               css('.attachment-management__drafts a').map { |a| a['href'] }).
        not_to include(manage_attachment_revision_path(notes, draft))
      expect(draft.reload).to be_ready
      expect(FoiAttachment.find(notes.id).body).to eq(attachment_text.b)
    end

    it 'shows a requester’s draft to an admin, who may confirm it' do
      sign_in(owner)
      draft = draft!(
        pdf,
        kind: 'pdf_redaction',
        boxes: { '1' => [AttachmentFixtures.letter_secret_box] }.to_json
      )
      sign_in(admin)
      get manage_attachment_revision_path(pdf, draft)
      expect(response).to have_http_status(:ok)
      confirm!(pdf, draft)
      expect(draft.reload).to be_applied
    end

    it 'won’t let a requester confirm a non-redaction draft once requesters may only redact' do
      AttachmentManagement.requester_access = 'replace'
      sign_in(owner)
      draft = draft!(notes,
                     kind: 'upload',
                     file: upload("Someone else’s text.\n", 'text/plain',
                                  'other.txt'))
      expect(draft).to be_ready

      AttachmentManagement.requester_access = nil
      get manage_attachment_revision_path(notes, draft)
      expect(response.body).to include('Only an admin can confirm this draft')
      confirm!(notes, draft)
      expect(flash[:error]).to include('Only an admin can confirm')
      expect(draft.reload).to be_ready
      expect(FoiAttachment.find(notes.id).body).to eq(attachment_text.b)
    end
  end

  describe 'the setting' do
    it 'gives the requester replacement with "replace", still not other people’s drafts' do
      AttachmentManagement.requester_access = 'replace'
      sign_in(admin)
      admins_draft = draft!(notes,
                            kind: 'upload',
                            file: upload("Admin text\n", 'text/plain', 'a.txt'))
      sign_in(owner)
      own = draft!(
        pdf,
        kind: 'upload',
        file: upload(
          AttachmentFixtures.pdf(
            pages: [AttachmentFixtures.letter_page(secret: 'Reviewed')]
          ),
          'application/pdf', 'r.pdf'
        )
      )
      expect(own).to be_ready
      get manage_attachment_revision_path(notes, admins_draft)
      expect(response).to have_http_status(:not_found)
    end

    it 'shuts the requester out with "none"' do
      AttachmentManagement.requester_access = 'none'
      sign_in(owner)
      get manage_attachment_path(notes)
      expect(response).to have_http_status(:not_found)
      get "/request/#{info_request.url_title}"
      expect(Nokogiri::HTML(response.body).css('a.attachment__manage')).
        to be_empty
    end
  end
end
