require 'spec_helper'
require 'zip'

RSpec.describe 'Background regulator pack with 48-hour signed link',
               type: :request do
  include ActiveJob::TestHelper
  include ActionMailer::TestHelper
  include_context 'with document OCR off'

  let(:requester) { FactoryBot.create(:user) }
  let(:other_user) { FactoryBot.create(:user) }
  let(:body) { FactoryBot.create(:public_body) }
  let(:info_request) do
    FactoryBot.create(:info_request, user: requester, public_body: body)
  end
  let(:docx_type) do
    'application/vnd.openxmlformats-officedocument.wordprocessingml.document'
  end

  after do
    FileUtils.rm_rf(RegulatorPack.storage_dir)
  end

  def read_zip_entries(zip_bytes)
    entries = {}
    Zip::InputStream.open(StringIO.new(zip_bytes)) do |io|
      while (entry = io.get_next_entry)
        entries[entry.name] = io.read
      end
    end
    entries
  end

  def zip_entries_from_token(token)
    payload = RegulatorPack.verify_token(token)
    zip_path = RegulatorPack.path_for(
      payload[:pack_id], info_request_id: payload[:info_request_id]
    )
    read_zip_entries(File.binread(zip_path))
  end

  def last_emailed_token
    mail = ActionMailer::Base.deliveries.last
    expect(mail).to be_present
    CGI.unescape(mail.body.decoded[/token=([^\s&]+)/, 1].to_s)
  end

  it 'queues the job, emails a signed link, remasks black_masked files from ' \
     'RawEmail with black rules only, and includes non-matching files' do
    CensorRule.create!(text: 'BlackSecret', replacement: '[black]',
                       colour: 'black', censorable: info_request,
                       last_edit_editor: 'admin',
                       last_edit_comment: 'black rule')
    CensorRule.create!(text: 'BlueSecret', replacement: '[blue]',
                       colour: 'blue', censorable: info_request,
                       last_edit_editor: 'admin',
                       last_edit_comment: 'blue rule')

    message = AttachmentFixtures.deliver(
      info_request,
      [['notes.txt', 'text/plain',
        'BlackSecret BlueSecret contact@example.com'],
       ['plain.txt', 'text/plain', 'No ruled words here']],
      text: 'Reply body: BlackSecret BlueSecret officer@example.org'
    )
    attachment = message.foi_attachments.find_by!(filename: 'notes.txt')
    plain = message.foi_attachments.find_by!(filename: 'plain.txt')
    main = message.get_main_body_text_part
    [attachment, plain, main].each(&:mask)
    expect(attachment.reload).to be_black_masked
    expect(main.reload).to be_black_masked
    expect(plain.reload).not_to be_black_masked

    doc = Disclosures::Creation.new(
      user: requester, attachment: attachment, kind: 'released_records'
    ).create!
    Disclosures::Publication.new(doc, user: FactoryBot.create(:admin_user)).
      publish!

    body_doc = Disclosures::Creation.new(
      user: requester, attachment: main, kind: 'decision_letter',
      email_text: true
    ).create!
    Disclosures::Publication.new(body_doc,
                                 user: FactoryBot.create(:admin_user)).publish!

    expect(attachment.reload.file.download).to include('[black]')
    expect(attachment.file.download).to include('[blue]')
    expect(attachment.file.download).not_to include('BlueSecret')
    expect(attachment.file.download).not_to include('contact@example.com')

    sign_in(requester)
    expect do
      get download_entire_request_path(url_title: info_request.url_title)
    end.to have_enqueued_job(InfoRequest::RegulatorPackJob).
      with(info_request, requester)
    expect(response).to redirect_to(show_request_path(info_request.url_title))

    ActionMailer::Base.deliveries.clear
    perform_enqueued_jobs do
      InfoRequest::RegulatorPackJob.perform_later(info_request, requester)
    end

    mail = ActionMailer::Base.deliveries.last
    expect(mail).to be_present
    expect(mail.to).to eq([requester.email])
    token = last_emailed_token
    expect(token).to be_present

    get download_regulator_pack_path(token: token)
    expect(response).to have_http_status(:ok)
    expect(response.content_type).to include('application/zip')

    entries = read_zip_entries(response.body)
    attachment_entry = entries.find { |name, _| name.end_with?('notes.txt') }
    expect(attachment_entry).to be_present
    expect(attachment_entry.last).to include('[black]')
    expect(attachment_entry.last).not_to include('BlackSecret')
    expect(attachment_entry.last).to include('BlueSecret')
    expect(attachment_entry.last).to include('contact@example.com')

    plain_entry = entries.find { |name, _| name.end_with?('plain.txt') }
    expect(plain_entry.last).to eq('No ruled words here')

    correspondence = entries['correspondence.txt']
    expect(correspondence).to include('[black]')
    expect(correspondence).not_to include('BlackSecret')
    expect(correspondence).to include('BlueSecret')
    expect(correspondence).to include('officer@example.org')
  end

  it 'falls back to stored file when a black_masked file matches no black ' \
     'rule on its original, and preserves the original filename otherwise' do
    CensorRule.create!(text: 'BlackSecret', replacement: '[black]',
                       colour: 'black', censorable: info_request,
                       last_edit_editor: 'admin',
                       last_edit_comment: 'black rule')
    secret_docx = DocumentFixtures.docx(paragraphs: ['Secret BlackSecret'])
    clean_docx = DocumentFixtures.docx(paragraphs: ['Routine public note'])
    masked_pdf = DocumentFixtures.text_pdf(title: 'Masked copy',
                                           paragraphs: ['Secret [black]'])
    clean_pdf = DocumentFixtures.text_pdf(title: 'Converted copy',
                                          paragraphs: ['Routine public note'])

    message = AttachmentFixtures.deliver(
      info_request,
      [['briefing.docx', docx_type, secret_docx],
       ['clean.docx', docx_type, clean_docx]]
    )
    secret_part = message.foi_attachments.find_by!(filename: 'briefing.docx')
    clean_part = message.foi_attachments.find_by!(filename: 'clean.docx')

    secret_part.content_type = 'application/pdf'
    secret_part.filename = 'briefing.pdf'
    secret_part.black_masked = true
    secret_part.masked_at = 1.minute.ago
    secret_part.replace_file!(masked_pdf, content_type: 'application/pdf')

    clean_part.content_type = 'application/pdf'
    clean_part.filename = 'clean.pdf'
    clean_part.black_masked = false
    clean_part.masked_at = 1.minute.ago
    clean_part.replace_file!(clean_pdf, content_type: 'application/pdf')

    token = RegulatorPack.new(info_request, user: requester).build!
    entries = zip_entries_from_token(token)

    expect(entries.keys.any? { _1.end_with?('briefing.pdf') }).to be(true)
    expect(entries.keys.any? { _1.end_with?('briefing.docx') }).to be(false)
    briefing_entry =
      entries.find { |name, _| name.end_with?('briefing.pdf') }.last
    expect(briefing_entry).to eq(masked_pdf)

    expect(entries.keys.any? { _1.end_with?('clean.docx') }).to be(true)
    expect(entries.keys.any? { _1.end_with?('clean.pdf') }).to be(false)
    clean_entry = entries.find { |name, _| name.end_with?('clean.docx') }.last
    expect(clean_entry).to eq(clean_docx)
  end

  it 'retries on transient masking errors in RegulatorPackJob and succeeds ' \
     'with the masked original when a retry passes' do
    CensorRule.create!(text: 'BlackSecret', replacement: '[black]',
                       colour: 'black', censorable: info_request,
                       last_edit_editor: 'admin',
                       last_edit_comment: 'black rule')
    pdf = DocumentFixtures.text_pdf(
      title: 'Report',
      paragraphs: ['Report mentioning BlackSecret']
    )
    message = AttachmentFixtures.deliver(
      info_request,
      [['report.pdf', 'application/pdf', pdf]],
      text: 'Main body BlackSecret text'
    )
    pdf_part = message.foi_attachments.find_by!(filename: 'report.pdf')
    main = message.get_main_body_text_part
    [pdf_part, main].each(&:mask)

    read_refusals = 0
    allow_any_instance_of(FoiAttachment).to receive(:original_attributes).
      and_wrap_original do |m, *a|
        read_refusals += 1
        raise MailHandler::ReadRefused, 'mail cell busy' if read_refusals == 1

        m.call(*a)
      end

    attempts = 0
    allow(AlaveteliTextMasker).to receive(:apply_masks).and_call_original
    allow(AlaveteliTextMasker).to receive(:apply_masks).
      with(anything, 'application/pdf', anything).and_wrap_original do |m, *a|
        attempts += 1
        if attempts <= 2
          raise AlaveteliTextMasker::PDFMaskingError, 'transient pdf fault'
        end

        m.call(*a)
      end

    ActionMailer::Base.deliveries.clear
    perform_enqueued_jobs do
      InfoRequest::RegulatorPackJob.perform_later(info_request, requester)
    end

    expect(attempts).to eq(3)
    entries = zip_entries_from_token(last_emailed_token)
    report_entry = entries.find { |name, _| name.end_with?('report.pdf') }
    expect(report_entry).to be_present
    expect(pdf_part.reload).not_to be_masking_failed
  end

  it 'falls back to stored files on the final retry attempt without ' \
     'omitting them, leaking raw bytes, or setting masking_failed_at' do
    CensorRule.create!(text: 'BlackSecret', replacement: '[black]',
                       colour: 'black', censorable: info_request,
                       last_edit_editor: 'admin',
                       last_edit_comment: 'black rule')
    pdf = DocumentFixtures.text_pdf(
      title: 'Sensitive PDF',
      paragraphs: ['Contains BlackSecret']
    )
    message = AttachmentFixtures.deliver(
      info_request,
      [['faulty.pdf', 'application/pdf', pdf],
       ['hidden.txt', 'text/plain', 'Hidden by admin']],
      text: 'Main body BlackSecret text'
    )
    faulty_pdf = message.foi_attachments.find_by!(filename: 'faulty.pdf')
    hidden_part = message.foi_attachments.find_by!(filename: 'hidden.txt')
    main = message.get_main_body_text_part
    [faulty_pdf, main].each(&:mask)
    hidden_part.update_columns(prominence: 'hidden',
                               prominence_reason: 'Admin hide')
    stored_pdf = faulty_pdf.reload.file.download
    expect(main.reload.file.download).to include('[black]')
    expect(main.file.download).not_to include('BlackSecret')

    pdf_calls = 0
    body_calls = 0
    allow(AlaveteliTextMasker).to receive(:apply_masks).and_call_original
    allow(AlaveteliTextMasker).to receive(:apply_masks).
      with(anything, 'application/pdf', anything) do
        pdf_calls += 1
        raise AlaveteliTextMasker::PDFMaskingError, 'persistent pdf error'
      end
    allow(AlaveteliTextMasker).to receive(:apply_masks).
      with(include('Main body BlackSecret'), 'text/plain', anything) do
        body_calls += 1
        raise Regexp::TimeoutError, 'persistent timeout'
      end

    ActionMailer::Base.deliveries.clear
    perform_enqueued_jobs do
      InfoRequest::RegulatorPackJob.perform_later(info_request, requester)
    end

    expect(body_calls).to eq(InfoRequest::RegulatorPackJob::MAX_MASKING_ATTEMPTS)
    expect(pdf_calls).to eq(1)

    entries = zip_entries_from_token(last_emailed_token)
    expect(entries.keys.any? { _1.end_with?('hidden.txt') }).to be(false)
    pdf_entry = entries.find { |name, _| name.end_with?('faulty.pdf') }
    expect(pdf_entry).to be_present
    expect(pdf_entry.last).to eq(stored_pdf)

    correspondence = entries['correspondence.txt']
    expect(correspondence).to include('[black]')
    expect(correspondence).not_to include('BlackSecret')

    expect(faulty_pdf.reload).not_to be_masking_failed
    expect(main.reload).not_to be_masking_failed
  end

  it 'keeps never-maskable encrypted PDFs in the ZIP from stored files after retries' do
    CensorRule.create!(text: 'BlackSecret', replacement: '[black]',
                       colour: 'black', censorable: info_request,
                       last_edit_editor: 'admin',
                       last_edit_comment: 'black rule')
    encrypted_pdf = '%PDF-1.4 encrypted-bytes'
    message = AttachmentFixtures.deliver(
      info_request,
      [['encrypted.pdf', 'application/pdf', encrypted_pdf]]
    )
    encrypted = message.foi_attachments.find_by!(filename: 'encrypted.pdf')
    encrypted.update_columns(black_masked: false,
                             masking_failed_at: 1.minute.ago)

    pdf_calls = 0
    allow(AlaveteliTextMasker).to receive(:apply_masks).and_call_original
    allow(AlaveteliTextMasker).to receive(:apply_masks).
      with(anything, 'application/pdf', anything) do
        pdf_calls += 1
        raise AlaveteliTextMasker::PDFMaskingError, 'encrypted pdf'
      end

    ActionMailer::Base.deliveries.clear
    perform_enqueued_jobs do
      InfoRequest::RegulatorPackJob.perform_later(info_request, requester)
    end

    expect(pdf_calls).to eq(InfoRequest::RegulatorPackJob::MAX_MASKING_ATTEMPTS)
    entries = zip_entries_from_token(last_emailed_token)
    encrypted_entry =
      entries.find { |name, _| name.end_with?('encrypted.pdf') }
    expect(encrypted_entry).to be_present
    expect(encrypted_entry.last).to eq(encrypted_pdf)
  end

  it 'falls back to FoiAttachment#file when RawEmail is gone or manually ' \
     'black-redacted' do
    CensorRule.create!(text: 'BlueSecret', replacement: '[blue]',
                       colour: 'blue', censorable: info_request,
                       last_edit_editor: 'admin',
                       last_edit_comment: 'blue rule')

    message = AttachmentFixtures.deliver(
      info_request,
      [['expired.txt', 'text/plain', 'BlueSecret kept-after-expiry'],
       ['manual.txt', 'text/plain', 'AdminBlackSecret visible-rest']]
    )
    expired_part = message.foi_attachments.find_by!(filename: 'expired.txt')
    manual_part = message.foi_attachments.find_by!(filename: 'manual.txt')

    doc = Disclosures::Creation.new(
      user: requester, attachment: expired_part, kind: 'released_records'
    ).create!
    Disclosures::Publication.new(doc, user: requester).publish!

    manual_part.replace_file!('[redacted] visible-rest')
    manual_part.update!(black_masked: true, masked_at: 1.minute.ago)
    manual_part.file_blob.update!(
      metadata: manual_part.file_blob.metadata.merge(
        'manual_black_mask' => true
      )
    )

    token_before_expiry = RegulatorPack.new(info_request, user: requester).
      build!
    entries = zip_entries_from_token(token_before_expiry)
    manual_entry = entries.find { |name, _| name.end_with?('manual.txt') }.last
    expect(manual_entry).to eq('[redacted] visible-rest')
    expect(manual_entry).not_to include('AdminBlackSecret')

    message.raw_email.file.purge
    token_after_expiry = RegulatorPack.new(info_request, user: requester).build!
    entries2 = zip_entries_from_token(token_after_expiry)
    expired_entry =
      entries2.find { |name, _| name.end_with?('expired.txt') }.last
    expect(expired_entry).to include('[blue]')
    expect(expired_entry).not_to include('BlueSecret')
  end

  it 'requires sign-in, rejects other users and expired links, and purges ' \
     'expired zips' do
    AttachmentFixtures.deliver(
      info_request, [['notes.txt', 'text/plain', 'Body text']]
    )
    token = RegulatorPack.new(info_request, user: requester).build!
    payload = RegulatorPack.verify_token(token)
    zip_path = RegulatorPack.path_for(
      payload[:pack_id], info_request_id: payload[:info_request_id]
    )
    expect(File.exist?(zip_path)).to be(true)

    get download_regulator_pack_path(token: token)
    expect(response).to be_redirect

    sign_in(other_user)
    get download_regulator_pack_path(token: token)
    expect(response).to have_http_status(:gone)

    travel 49.hours do
      sign_in(requester)
      get download_regulator_pack_path(token: token)
      expect(response).to have_http_status(:gone)

      removed = RegulatorPack.purge_expired!
      expect(removed).to eq(1)
      expect(File.exist?(zip_path)).to be(false)
    end
  end

  it 'invalidates built packs on InfoRequest#expire, sanitises HTML, ' \
     'retries on ReadRefused, and debounces clicks' do
    AttachmentFixtures.deliver(
      info_request,
      [['page.html', 'text/html',
        '<html><body><script>alert(1)</script><p>Safe text</p></body></html>']]
    )

    token = RegulatorPack.new(info_request, user: requester).build!
    payload = RegulatorPack.verify_token(token)
    zip_path = RegulatorPack.path_for(
      payload[:pack_id], info_request_id: payload[:info_request_id]
    )
    entries = read_zip_entries(File.binread(zip_path))
    html_entry = entries.find { |name, _| name.end_with?('page.html') }.last
    expect(html_entry).to include('Safe text')
    expect(html_entry).not_to include('<script')

    info_request.expire
    expect(File.exist?(zip_path)).to be(false)
    sign_in(requester)
    get download_regulator_pack_path(token: token)
    expect(response).to have_http_status(:gone)

    allow_any_instance_of(FoiAttachment).to receive(:original_attributes).
      and_raise(MailHandler::ReadRefused, 'mail cell busy')
    expect do
      RegulatorPack.new(info_request, user: requester).build!
    end.to raise_error(MailHandler::ReadRefused)
    expect do
      InfoRequest::RegulatorPackJob.perform_now(info_request, requester)
    end.to have_enqueued_job(InfoRequest::RegulatorPackJob)

    memory_cache = ActiveSupport::Cache::MemoryStore.new
    allow(Rails).to receive(:cache).and_return(memory_cache)
    expect do
      get download_entire_request_path(url_title: info_request.url_title)
      get download_entire_request_path(url_title: info_request.url_title)
    end.to have_enqueued_job(InfoRequest::RegulatorPackJob).exactly(:once)
  end

  it 'purges cached regulator packs when an attachment replacement is applied' do
    message = AttachmentFixtures.deliver(
      info_request, [['notes.txt', 'text/plain', 'Original text.']]
    )
    part = message.foi_attachments.find_by!(filename: 'notes.txt')

    token = RegulatorPack.new(info_request, user: requester).build!
    payload = RegulatorPack.verify_token(token)
    zip_path = RegulatorPack.path_for(
      payload[:pack_id], info_request_id: payload[:info_request_id]
    )
    expect(File.exist?(zip_path)).to be(true)

    admin = FactoryBot.create(:admin_user)
    builder = AttachmentManagement::NewRevision.new(
      part, user: admin, ability: Ability.new(admin)
    )
    rev, input = builder.build('text_edit', text: 'Replaced text.')
    rev.save!
    rev.output.attach(io: StringIO.new(input.b), filename: 'input',
                      content_type: 'application/octet-stream',
                      identify: false)
    AttachmentManagement::Processor.new(rev).run

    AttachmentManagement::Replacement.new(
      rev.reload, editor: admin, reason: 'Update text'
    ).apply!

    expect(File.exist?(zip_path)).to be(false)
  end
end
