require 'spec_helper'

RSpec.describe 'Pre-publish safety checks', type: :request do
  include ActiveJob::TestHelper
  include DisclosuresHelpers
  include SettingsHelpers
  include_context 'with document OCR off'

  let(:owner) do
    FactoryBot.create(:user, name: 'Rowan Requester',
                             email: 'rowan.requester@example.org')
  end
  let(:info_request) { FactoryBot.create(:info_request, user: owner) }

  def deliver_document(name, content_type, bytes)
    message = AttachmentFixtures.deliver(info_request,
                                         [[name, content_type, bytes]])
    attachment = message.get_attachments_for_display.
                 find { _1.filename == name }
    read_by_analyzer(attachment)
    doc = Disclosures::Creation.new(
      user: owner, attachment: attachment, kind: 'released_records'
    ).create!
    [message, attachment, doc]
  end

  def raster_document(name)
    pdf = DocumentFixtures.text_pdf(title: 'Scan', paragraphs: ['Plain page'])
    _message, attachment, doc = deliver_document(name, 'application/pdf', pdf)
    attachment.file_blob.update!(
      metadata: attachment.file_blob.metadata.merge('rasterized' => true)
    )
    [attachment, doc]
  end

  def expect_sent_for_review(doc, reason)
    expect(Disclosures::RequesterPublication.publish!(doc, user: owner)).
      to eq(:review)
    expect(Disclosures::ReviewSubmission.pending?(doc.reload)).to be(true)
    expect(Disclosures::ReviewSubmission.reason(doc)).to match(reason)
  end

  describe 'Office files' do
    let(:docx_type) do
      'application/vnd.openxmlformats-officedocument.' \
        'wordprocessingml.document'
    end

    it 'sends it for admin review when a blue censor rule matches' do
      FactoryBot.create(:censor_rule, censorable: info_request,
                                      colour: 'blue',
                                      text: 'BlueOfficeSecret',
                                      replacement: '[blue]')
      docx = AttachmentFixtures.docx(
        paragraphs: ['Summary containing BlueOfficeSecret.']
      )
      _message, attachment, doc = deliver_document('report.docx', docx_type,
                                                   docx)

      expect_sent_for_review(doc, /privacy check/i)

      expect(attachment.reload.prominence).to eq('requester_only')
      expect(doc.reload.state).to eq('draft')
      expect(doc.pages.count).to eq(0)
      expect(doc.thumbnail).not_to be_attached
    end

    it 'sends it for admin review when a login link or reply address is present' do
      login_url = "https://#{AlaveteliConfiguration.domain}/c/secret-token-123"
      docx_login = AttachmentFixtures.docx(
        paragraphs: ["Sign in here: #{login_url}"]
      )
      _msg1, att1, doc1 = deliver_document('login.docx', docx_type, docx_login)

      expect_sent_for_review(doc1, /sign-in link/i)
      expect(att1.reload.prominence).to eq('requester_only')
      expect(doc1.reload.state).to eq('draft')
      expect(doc1.pages.count).to eq(0)

      docx_reply = AttachmentFixtures.docx(
        paragraphs: ["Reply to #{info_request.incoming_email}"]
      )
      _msg2, att2, doc2 = deliver_document('reply.docx', docx_type, docx_reply)

      expect_sent_for_review(doc2, /reply address/i)
      expect(att2.reload.prominence).to eq('requester_only')
      expect(doc2.reload.state).to eq('draft')
      expect(doc2.pages.count).to eq(0)
    end
  end

  describe 'box-redacted (rasterized) PDFs' do
    it 'applies orange and blue masks before rasterizing drawn boxes' do
      FactoryBot.create(:censor_rule, censorable: info_request,
                                      colour: 'blue',
                                      text: 'BlueOnlySecret',
                                      replacement: '[blue]')
      login_url = "https://#{AlaveteliConfiguration.domain}/c/tok999"
      pdf = DocumentFixtures.text_pdf(
        title: 'Briefing',
        paragraphs: [
          'Keep this public heading.',
          'BlueOnlySecret and officer@council.example and Mobile: 07700 900123',
          "Links: #{login_url} and #{info_request.incoming_email}",
          'ManualBoxTarget'
        ]
      )
      message, attachment, doc = deliver_document('briefing.pdf',
                                                  'application/pdf', pdf)

      captured_input = nil
      allow(AttachmentManagement::Processor).
        to receive(:new).and_wrap_original do |m, *args, **kwargs|
          captured_input = kwargs[:source_bytes]
          m.call(*args, **kwargs)
        end

      with_setting(Disclosures, :review_requester_redactions, false) do
        sign_in owner
        post publish_reply_redact_path(url_title: info_request.url_title,
                                       message_id: message.id, id: doc),
             params: {
               kind: 'pdf_redaction',
               boxes: { '1' => [[0.0, 0.8, 0.4, 0.9]] }.to_json
             }
      end

      expect(captured_input).not_to be_nil
      masked_text = AttachmentManagement.sandboxed(
        input: captured_input, input_name: 'masked.pdf'
      ) do |job|
        Disclosures::PDFText.pages(job.input, 1, job.scratch, job: job).
          first.text
      end
      expect(masked_text).not_to include('BlueOnlySecret')
      expect(masked_text).not_to include('officer@council.example')
      expect(masked_text).not_to include('07700 900123')
      expect(masked_text).not_to include('tok999')
      expect(masked_text).not_to include(info_request.incoming_email)
      expect(masked_text).to include('Keep this public heading.')
      expect(attachment.reload.file_blob.metadata['rasterized']).to be(true)
      expect(doc.reload.state).to eq('published')
    end

    it 'refuses box redaction when public masking fails on a PDF' do
      pdf = DocumentFixtures.text_pdf(title: 'Briefing',
                                      paragraphs: ['Secret text'])
      message, attachment, doc = deliver_document('briefing.pdf',
                                                  'application/pdf', pdf)

      allow(Disclosures::Masking).to receive(:public_masked_bytes).
        and_raise(Disclosures::Error::Refused,
                  'This file couldn’t be masked for publication.')

      sign_in owner
      post publish_reply_redact_path(url_title: info_request.url_title,
                                     message_id: message.id, id: doc),
           params: {
             kind: 'pdf_redaction',
             boxes: { '1' => [[0.0, 0.8, 0.4, 0.9]] }.to_json
           }

      expect(response).to redirect_to(
        publish_reply_redact_path(url_title: info_request.url_title,
                                  message_id: message.id, id: doc)
      )
      expect(attachment.reload.file_blob.metadata['rasterized']).to be_nil
      expect(doc.reload.state).to eq('draft')
    end

    it 'sends it for admin review when OCR on a rasterized PDF hits a rule or always-removed pattern' do
      FactoryBot.create(:censor_rule, censorable: info_request,
                                      colour: 'blue',
                                      text: 'HiddenBlueWord',
                                      replacement: '[blue]')
      with_setting(Disclosures, :ocr, true) do
        attachment, doc = raster_document('scan.pdf')
        allow(Disclosures::Ocr).to receive(:pdf_page).
          and_return('Scanned text containing HiddenBlueWord')

        expect_sent_for_review(doc, /privacy check/i)
        expect(attachment.reload.prominence).to eq('requester_only')
        expect(doc.reload.state).to eq('draft')
        expect(doc.pages.count).to eq(0)

        attachment, doc = raster_document('scan-login.pdf')
        login_url = "https://#{AlaveteliConfiguration.domain}/c/ocr-token"
        allow(Disclosures::Ocr).to receive(:pdf_page).
          and_return("Scanned page with #{login_url}")

        expect_sent_for_review(doc, /sign-in link/i)
        expect(attachment.reload.prominence).to eq('requester_only')
        expect(doc.reload.state).to eq('draft')
        expect(doc.pages.count).to eq(0)
      end
    end

    it 'sends it for admin review when OCR on a rasterized or scanned PDF ' \
       'contains an unmasked email or mobile number' do
      pdf = DocumentFixtures.text_pdf(title: 'Scan', paragraphs: ['Plain page'])
      _msg1, raster_att, raster_doc = deliver_document(
        'raster.pdf', 'application/pdf', pdf
      )
      raster_att.file_blob.update!(
        metadata: raster_att.file_blob.metadata.merge('rasterized' => true)
      )

      scan_pdf = DocumentFixtures.text_pdf(title: 'Scan', paragraphs: [''])
      _msg2, scan_att, scan_doc = deliver_document(
        'scanned.pdf', 'application/pdf', scan_pdf
      )

      with_setting(Disclosures, :ocr, true) do
        allow(Disclosures::Ocr).to receive(:pdf_page).
          and_return('Contact citizen@example.org for details.')

        expect_sent_for_review(raster_doc, /personal details/i)
        expect(raster_att.reload.prominence).to eq('requester_only')
        expect(raster_doc.reload.state).to eq('draft')
        expect(raster_doc.pages.count).to eq(0)

        allow(Disclosures::Ocr).to receive(:pdf_page).
          and_return('Call Mobile: 07700 900456 urgently.')

        expect_sent_for_review(scan_doc, /personal details/i)
        expect(scan_att.reload.prominence).to eq('requester_only')
        expect(scan_doc.reload.state).to eq('draft')
        expect(scan_doc.pages.count).to eq(0)
      end
    end

    it 'sends it for admin review when OCR on a flagged picture inside a ' \
       'text PDF contains an unmasked email or mobile number' do
      pdf = DocumentFixtures.text_pdf(
        title: 'Report with embedded screenshot',
        paragraphs: [
          'This text-based PDF page has more than forty characters of clean ' \
          'body text so pdftotext reads it directly.'
        ]
      )
      _msg, attachment, doc = deliver_document(
        'screenshot.pdf', 'application/pdf', pdf
      )

      with_setting(Disclosures, :ocr, true) do
        allow(PDFRedactor::Survey).to receive(:pages).and_return(
          [{ 'number' => 1, 'visible' => 100, 'unmapped' => 0,
             'picture_share' => 0.25 }]
        )
        allow(Disclosures::Ocr).to receive(:pdf_page).
          and_return('Screenshot showing private.person@example.org')

        expect_sent_for_review(doc, /personal details/i)
        expect(attachment.reload.prominence).to eq('requester_only')
        expect(doc.reload.state).to eq('draft')
        expect(doc.pages.count).to eq(0)
      end
    end
  end
end
