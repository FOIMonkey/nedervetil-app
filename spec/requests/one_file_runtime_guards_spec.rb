require 'spec_helper'

RSpec.describe 'One-file runtime view and controller guards', type: :request do
  include ActiveJob::TestHelper
  include DisclosuresHelpers
  include_context 'with document OCR off'

  let(:owner) { FactoryBot.create(:user, name: 'Rowan Requester') }
  let(:admin) { FactoryBot.create(:admin_user) }
  let(:info_request) { FactoryBot.create(:info_request, user: owner) }

  it 'renders publish_reply choose screen when a draft document already exists' do
    pdf = DocumentFixtures.text_pdf(title: 'Decision', paragraphs: ['Text'])
    message = suggest_documents do
      AttachmentFixtures.deliver(
        info_request, [['decision.pdf', 'application/pdf', pdf]]
      )
    end
    attachment = message.get_attachments_for_display.first
    Disclosures::Creation.new(
      user: owner, attachment: attachment, kind: 'decision_letter'
    ).create!

    sign_in owner
    get publish_reply_path(url_title: info_request.url_title,
                           message_id: message.id)
    expect(response).to have_http_status(:ok)
    expect(response.body).to include('decision.pdf')
  end

  it 'renders admin censor rules list when redaction_tracking is enabled' do
    AlaveteliFeatures.backend.enable(:redaction_tracking)
    FactoryBot.create(:censor_rule, censorable: info_request,
                                    text: 'SecretWord',
                                    replacement: '[redacted]')

    sign_in admin
    get admin_request_path(info_request)
    expect(response).to have_http_status(:ok)
    expect(response.body).to include('SecretWord')
  ensure
    AlaveteliFeatures.backend.disable(:redaction_tracking)
  end

  it 'handles admin attachment edit and download_unmasked after 120-day RawEmail expiry' do
    message = AttachmentFixtures.deliver(
      info_request,
      [['broken.pdf', 'application/pdf', 'not-really-a-pdf']],
      text: 'Main reply text.'
    )
    main_part = message.get_main_body_text_part
    broken = message.foi_attachments.find { _1.filename == 'broken.pdf' }
    broken.update!(masking_failed_at: Time.current)
    broken.file_blob.update!(
      metadata: broken.file_blob.metadata.merge(
        'masking_fault' => 'AlaveteliTextMasker::PDFMaskingError: bad pdf',
        'served_after_fault' => 'as_it_came'
      )
    )

    message.raw_email.update!(read_at: 130.days.ago)
    message.raw_email.file.purge
    expect(message.raw_email.reload).to be_expired
    expect(message.raw_email).not_to be_erased

    sign_in admin
    get edit_admin_foi_attachment_path(main_part)
    expect(response).to have_http_status(:ok)
    expect(response.body).to include('original email is no longer')

    get edit_admin_foi_attachment_path(broken)
    expect(response).to have_http_status(:ok)
    expect(response.body).not_to include(
      download_unmasked_admin_foi_attachment_path(broken)
    )

    get download_unmasked_admin_foi_attachment_path(broken)
    expect(response).to have_http_status(:not_found)
  end

  describe 'GET publish_reply_read_path on draft documents' do
    let(:docx_type) do
      'application/vnd.openxmlformats-officedocument.' \
        'wordprocessingml.document'
    end

    it 'renders draft PDF previews, inline text/CSV/email_text, and binary ' \
       'download links without errors' do
      pdf = DocumentFixtures.text_pdf(title: 'Draft PDF',
                                      paragraphs: ['PDF content'])
      docx = AttachmentFixtures.docx(paragraphs: ['Office content'])
      message = AttachmentFixtures.deliver(
        info_request,
        [['draft.pdf', 'application/pdf', pdf],
         ['data.csv', 'text/csv', "col1,col2\nalpha,beta\n"],
         ['briefing.docx', docx_type, docx]],
        text: 'Main email body text for reading.'
      )
      pdf_part = message.foi_attachments.find_by!(filename: 'draft.pdf')
      csv_part = message.foi_attachments.find_by!(filename: 'data.csv')
      docx_part = message.foi_attachments.find_by!(filename: 'briefing.docx')
      main_part = message.get_main_body_text_part
      read_by_analyzer(docx_part)

      pdf_doc = Disclosures::Creation.new(
        user: owner, attachment: pdf_part, kind: 'released_records'
      ).create!
      csv_doc = Disclosures::Creation.new(
        user: owner, attachment: csv_part, kind: 'released_records'
      ).create!
      email_doc = Disclosures::Creation.new(
        user: owner, attachment: main_part, kind: 'decision_letter',
        email_text: true
      ).create!
      docx_doc = Disclosures::Creation.new(
        user: owner, attachment: docx_part, kind: 'released_records'
      ).create!

      sign_in owner
      args = { url_title: info_request.url_title, message_id: message.id }

      get publish_reply_read_path(**args, id: pdf_doc)
      expect(response).to have_http_status(:ok)
      expect(response.body).
        to include(manage_attachment_page_path(pdf_part, page: 1))

      pdf_part.update!(black_masked: true)
      get publish_reply_read_path(**args, id: pdf_doc)
      expect(response).to have_http_status(:ok)
      expect(response.body).not_to include(
        manage_attachment_page_path(pdf_part, page: 1)
      )
      expect(response.body).to include(info_request.url_title)

      get publish_reply_read_path(**args, id: csv_doc)
      expect(response).to have_http_status(:ok)
      expect(response.body).to include('alpha,beta')

      get publish_reply_read_path(**args, id: email_doc)
      expect(response).to have_http_status(:ok)
      expect(response.body).to include('Main email body text for reading.')

      get publish_reply_read_path(**args, id: docx_doc)
      expect(response).to have_http_status(:ok)
      doc_page = Nokogiri::HTML(response.body)
      download_href = doc_page.at_css('.publish-ask__what a')['href']
      expect(download_href).to include(info_request.url_title)
      get download_href
      expect(response).to have_http_status(:ok)
    end
  end
end
