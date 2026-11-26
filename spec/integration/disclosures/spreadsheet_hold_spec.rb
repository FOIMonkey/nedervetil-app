require 'spec_helper'

RSpec.describe 'Holding back a suspect spreadsheet' do
  include ActiveJob::TestHelper
  include ActiveSupport::Testing::TimeHelpers

  let(:owner) { FactoryBot.create(:user) }
  let(:info_request) { FactoryBot.create(:info_request, user: owner) }
  let(:fixtures) { Rails.root.join('gems/excel_analyzer/spec/fixtures') }
  let(:hidden_data) do
    File.binread(fixtures.join('suspect.xlsx'))
  end
  let(:xlsx_type) { ExcelAnalyzer::XlsxAnalyzer::CONTENT_TYPE }

  def deliver(bytes, name: 'figures.xlsx', type: xlsx_type)
    message = AttachmentFixtures.deliver(info_request, [[name, type, bytes]])
    message.get_attachments_for_display.first.then do |part|
      FoiAttachment.find(part.id)
    end
  end

  def download_path(attachment)
    "/request/#{info_request.url_title}/response/" \
      "#{attachment.incoming_message_id}/attach/" \
      "#{attachment.url_part_number}/#{attachment.display_filename}"
  end

  def download(attachment)
    get download_path(attachment)
    follow_redirect! while response.status == 302
  end

  def analyse(attachment)
    ActiveStorage::AnalyzeJob.perform_now(attachment.file_blob)
    attachment.reload
  end

  it 'hides a file the analyzer suspects, tells admins, and never says why' do
    attachment = deliver(hidden_data)
    sign_in(owner)

    ActionMailer::Base.deliveries.clear
    perform_enqueued_jobs(only: ActionMailer::MailDeliveryJob) do
      analyse(attachment)
    end
    expect(attachment.prominence).to eq('hidden')
    expect(attachment.file_blob.reload.metadata['excel']).to be_present

    event = info_request.reload.info_request_events.
      where(event_type: 'edit_attachment').last
    expect(event.params[:attachment_id]).to eq(attachment.id)

    report = ActionMailer::Base.deliveries.last
    expect(report.to).to eq([AlaveteliConfiguration.contact_email])
    expect(report.body.to_s).to include(attachment.id.to_s, 'Hidden')

    get "/request/#{info_request.url_title}"
    # The theme hides .hidden_attachment, so the message needs its own class.
    expect(Nokogiri::HTML(response.body).at_css('.attachment__held').text).
      to include('We’ve held this file back while we check it')
    expect(response.body).not_to match(/hidden (sheet|data|row|column)|pivot/i)
    download(attachment)
    expect(response).not_to have_http_status(:ok)
    expect(response.body).not_to include('Hidden sheet')
  end

  it 'keeps a suspect spreadsheet unread when its hold cannot be saved' do
    attachment = deliver(hidden_data)
    allow_any_instance_of(FoiAttachment).to receive(:valid?).and_return(false)

    expect { analyse(attachment) }.to raise_error(ActiveRecord::RecordInvalid)
    expect(attachment.file_blob.reload).not_to be_analyzed
    expect(Ability.new(owner).can?(:read, attachment.reload)).to be(false)
  end

  it 'queues the admin report on the worker default queue' do
    attachment = deliver(hidden_data)
    clear_enqueued_jobs

    analyse(attachment)

    expect(ActionMailer::MailDeliveryJob).
      to have_been_enqueued.on_queue('default')
  end

  it 'retries a report that could not be queued after applying the hold' do
    attachment = deliver(hidden_data)
    calls = 0
    allow(SpreadsheetHoldMailer).to receive(:report).
      and_wrap_original do |original, *args|
        calls += 1
        raise 'synthetic enqueue failure' if calls == 1

        original.call(*args)
      end

    expect { analyse(attachment) }.to raise_error('synthetic enqueue failure')
    expect(attachment.reload.prominence).to eq('hidden')
    expect(attachment.file_blob.reload).not_to be_analyzed

    clear_enqueued_jobs
    perform_enqueued_jobs(only: ActionMailer::MailDeliveryJob) do
      analyse(attachment)
    end
    expect(attachment.file_blob.reload).to be_analyzed
    expect(calls).to be >= 2
    expect(ActionMailer::Base.deliveries.last.to).
      to eq([AlaveteliConfiguration.contact_email])
  end

  it 'keeps a new spreadsheet from everyone but admins until it’s been read' do
    attachment = deliver(File.binread(fixtures.join('data.xlsx')))
    expect(attachment.file).not_to be_analyzed
    sign_in(owner)
    download(attachment)
    expect(response).not_to have_http_status(:ok)
    expect(Ability.new(owner).can?(:create_document, attachment)).to be(false)
    expect(Ability.new(FactoryBot.create(:admin_user)).can?(:read, attachment)).
      to be(true)

    get "/request/#{info_request.url_title}"
    expect(Nokogiri::HTML(response.body).at_css('.attachment__held').text).
      to eq('figures.xlsx: Getting it ready')

    analyse(attachment)
    download(attachment)
    expect(response).to have_http_status(:ok)
  end

  it 'says a spreadsheet an admin hides while it’s being read is hidden, not getting ready' do
    attachment = deliver(File.binread(fixtures.join('data.xlsx')))
    attachment.update!(prominence: 'hidden', prominence_reason: 'Synthetic')
    sign_in(owner)
    get "/request/#{info_request.url_title}"
    expect(Nokogiri::HTML(response.body).at_css('.attachment__held').text.squish).
      to eq('We’ve hidden this file. ' \
            'Please contact us if you have any questions.')
    expect(response.body).not_to include('figures.xlsx', 'Synthetic')
  end

  it 'holds a macro-enabled workbook as it does any other' do
    attachment = deliver(hidden_data,
                         name: 'figures.xlsm',
                         type: 'application/vnd.ms-excel.sheet.macroEnabled.12')
    analyse(attachment)
    expect(attachment.prominence).to eq('hidden')
    expect(attachment.file_blob.reload.metadata['excel']).to be_present
  end

  it 'holds a suspect .xls as it does a suspect .xlsx' do
    attachment = deliver(File.binread(fixtures.join('suspect.xls')),
                         name: 'legacy.xls',
                         type: ExcelAnalyzer::XlsAnalyzer::CONTENT_TYPE)
    analyse(attachment)
    expect(attachment.prominence).to eq('hidden')
    expect(attachment.file_blob.reload.metadata['excel']).to be_present
    sign_in(owner)
    download(attachment)
    expect(response).not_to have_http_status(:ok)
  end

  it 'leaves an ordinary .xls alone' do
    attachment = deliver(File.binread(fixtures.join('data.xls')),
                         name: 'plain.xls',
                         type: ExcelAnalyzer::XlsAnalyzer::CONTENT_TYPE)
    analyse(attachment)
    expect(attachment.prominence).to eq('requester_only')
  end

  it 'keeps a held file out of publishing' do
    attachment = deliver(hidden_data)
    analyse(attachment)
    expect(Ability.new(owner).can?(:create_document, attachment)).to be(false)
  end

  it 'leaves an ordinary spreadsheet alone' do
    clean = File.binread(fixtures.join('data.xlsx'))
    attachment = deliver(clean)
    analyse(attachment)
    expect(attachment.prominence).to eq('requester_only')
  end

  describe 'named ranges and links to other workbooks, and nothing else' do
    let(:metadata) do
      { data_model: 0, external_links: 1, hidden_columns: 0, hidden_rows: 0,
        hidden_sheets: 0, named_ranges: 2, pivot_cache: 0 }
    end

    def hold(cells)
      bytes = OfficeFixtures.workbook(
        sheets: {
          'xl/worksheets/sheet1.xml' => OfficeFixtures.sheet_xml(cells)
        },
        core: nil
      )
      attachment = deliver(bytes)
      Disclosures::SpreadsheetHold.new(attachment.file_blob, metadata).run
      attachment.reload.prominence
    end

    it 'holds them as before without the PII check' do
      expect(hold([%w[Depot Vans]])).to eq('hidden')
    end

    context 'with the PII check switched on' do
      before do
        allow(AlaveteliConfiguration).to receive(:disclosures_pii_check).
          and_return('presidio')
        allow(AlaveteliConfiguration).
          to receive(:disclosures_pii_check_endpoint).
          and_return('http://127.0.0.1:5002')
      end

      def presidio(found, status: 200)
        stub_request(:post, 'http://127.0.0.1:5002/analyze').
          to_return(status: status, body: found.to_json,
                    headers: { 'Content-Type' => 'application/json' })
      end

      it 'leaves alone a file that doesn’t look personal, as WDTK does' do
        presidio([])
        expect(hold([%w[Depot Vans]])).to eq('requester_only')
      end

      it 'sends each distinct workbook cell once' do
        request = stub_request(:post, 'http://127.0.0.1:5002/analyze').
                  with(body: hash_including('text' => "Depot\nVans")).
                  to_return(status: 200, body: [].to_json,
                            headers: { 'Content-Type' => 'application/json' })
        expect(hold([%w[Depot Vans]] * 20)).to eq('requester_only')
        expect(request).to have_been_requested
      end

      it 'checks the file of a requester who opted out of AI reading like anyone’s' do
        skip 'IncomingAttention::OptOut arrives in B10' unless defined?(IncomingAttention::OptOut)

        IncomingAttention::OptOut.set!(owner, true)
        request = presidio([])
        expect(hold([%w[Depot Vans]])).to eq('requester_only')
        expect(request).to have_been_requested
      end

      it 'holds one the check finds names in, or can’t check' do
        presidio([{ entity_type: 'PERSON', score: 0.9 }])
        expect(hold([['Officer', 'Anjali Raval']])).to eq('hidden')
        presidio({}, status: 503)
        expect(hold([%w[Depot Vans]])).to eq('hidden')
      end

      it 'holds one with an email address in it, whatever the check says' do
        presidio([])
        expect(hold([['Contact', 'roads@example.org']])).to eq('hidden')
        expect(hold([['Contact', 'jane.doe@gov.wales']])).to eq('hidden')
      end

      it 'holds one when the check breaks, and logs which error by its class' do
        allow(Disclosures::PiiCheck).to receive(:call).
          and_raise(NoMethodError, 'Officer Anjali Raval')
        allow(Rails.logger).to receive(:warn).and_call_original
        expect(hold([['Officer', 'Anjali Raval']])).to eq('hidden')
        attachment = FoiAttachment.find_by!(filename: 'figures.xlsx')
        expect(Rails.logger).to have_received(:warn).
          with('spreadsheet_hold_personal_check_failed ' \
               "attachment_id=#{attachment.id} NoMethodError")
      end
    end

    it 'still holds a file with anything else hidden' do
      bytes = OfficeFixtures.workbook(core: nil)
      attachment = deliver(bytes)
      Disclosures::SpreadsheetHold.new(attachment.file_blob,
                                       metadata.merge(hidden_rows: 3)).run
      expect(attachment.reload.prominence).to eq('hidden')
    end
  end

  it 'doesn’t take a file away from its requester by reading it again' do
    attachment = deliver(hidden_data)
    analyse(attachment)
    attachment.update!(prominence: 'requester_only', prominence_reason: nil)
    ActionMailer::Base.deliveries.clear

    expect(SpreadsheetHoldMailer).not_to receive(:report)
    analyse(attachment)
    expect(attachment.prominence).to eq('requester_only')
    expect(ActionMailer::Base.deliveries).to be_empty
  end

  it 'holds a suspect file the first time it’s read, however old it is' do
    attachment = deliver(hidden_data)
    attachment.incoming_message.update_columns(sent_at: 2.days.ago,
                                               created_at: 2.days.ago)
    analyse(attachment)
    expect(attachment.prominence).to eq('hidden')
  end

  it 'never lets a file that’s not been read reach its requester' do
    attachment = deliver(hidden_data)
    travel_to(3.days.from_now) do
      sign_in(owner)
      expect(Disclosures::SpreadsheetHold.waiting?(FoiAttachment.find(attachment.id))).
        to be(true)
      download(attachment)
      expect(response).not_to have_http_status(:ok)
    end
  end

  it 'queues the analysis of a parsed spreadsheet' do
    clear_enqueued_jobs
    attachment = deliver(File.binread(fixtures.join('data.xlsx')))
    expect(ActiveStorage::AnalyzeJob).
      to have_been_enqueued.with(attachment.file_blob)
  end

  describe 'following up a parse' do
    let(:job) { Disclosures::SpreadsheetCheckJob }

    it 'follows up each parse that found a spreadsheet' do
      clear_enqueued_jobs
      attachment = deliver(File.binread(fixtures.join('data.xlsx')))
      expect(job).to have_been_enqueued.with(attachment.incoming_message_id)
    end

    it 'follows up a parse that went wrong too' do
      attachment = deliver(File.binread(fixtures.join('data.xlsx')))
      message = attachment.incoming_message
      clear_enqueued_jobs
      allow(message).to receive(:extract_attachments).and_raise('Stopped')
      expect { message.parse_raw_email! }.to raise_error('Stopped')
      expect(job).to have_been_enqueued.with(message.id)
    end

    it 'queues the analysis again until it’s run, then stops' do
      attachment = deliver(hidden_data)
      clear_enqueued_jobs

      job.perform_now(attachment.incoming_message_id)
      expect(ActiveStorage::AnalyzeJob).
        to have_been_enqueued.with(attachment.file_blob)
      expect(job).to have_been_enqueued.
        with(attachment.incoming_message_id, 1)

      analyse(attachment)
      expect(attachment.prominence).to eq('hidden')
      clear_enqueued_jobs
      job.perform_now(attachment.incoming_message_id, 1)
      expect(enqueued_jobs).to be_empty
    end

    it 'tells an admin if it never runs, and still keeps the file back' do
      attachment = deliver(hidden_data)
      ActionMailer::Base.deliveries.clear

      job.perform_now(attachment.incoming_message_id, job::WAITS.size - 1)

      report = ActionMailer::Base.deliveries.last
      expect(report.to).to eq([AlaveteliConfiguration.contact_email])
      expect(report.subject).to include(attachment.id.to_s)
      expect(Disclosures::SpreadsheetHold.waiting?(attachment.reload)).
        to be(true)
    end

    it 'finds what no job is following' do
      unread = deliver(File.binread(fixtures.join('data.xlsx')))
      read = deliver(hidden_data, name: 'other.xlsx')
      analyse(read)
      expect(Disclosures::SpreadsheetHold.unread).to include(unread)
      expect(Disclosures::SpreadsheetHold.unread).not_to include(read)
    end
  end

  it 'leaves a reply another process parsed while it waited for the lock' do
    attachment = deliver(File.binread(fixtures.join('data.xlsx')))
    id = attachment.incoming_message_id
    IncomingMessage.where(id: id).update_all(last_parsed: nil)
    waiting = IncomingMessage.find(id)
    IncomingMessage.where(id: id).update_all(last_parsed: Time.zone.now,
                                             subject: 'Parsed elsewhere')
    expect(waiting).not_to receive(:extract_attachments)

    waiting.parse_raw_email

    expect(waiting.subject).to eq('Parsed elsewhere')
    expect(waiting.last_parsed).to be_present
    expect(waiting).not_to be_changed
  end

  describe 'misnamed .xls, ZIP archives, and embedded spreadsheets' do
    let(:clean_xlsx) { File.binread(fixtures.join('data.xlsx')) }
    let(:suspect_xls) { File.binread(fixtures.join('suspect.xls')) }
    let(:docx_type) do
      'application/vnd.openxmlformats-officedocument.wordprocessingml.document'
    end

    it 'probes a misnamed .xlsx uploaded as .xls without running LibreOffice' do
      attachment = deliver(hidden_data, name: 'figures.xls',
                                        type: ExcelAnalyzer::XlsAnalyzer::CONTENT_TYPE)
      expect_any_instance_of(ExcelAnalyzer::XlsAnalyzer).
        not_to receive(:convert)

      analyse(attachment)
      expect(attachment.prominence).to eq('hidden')
    end

    it 'holds a new .zip until analyzed, then releases a clean one' do
      archive = OfficeFixtures.package(
        { 'notes.txt' => 'hello', 'clean.xlsx' => clean_xlsx }
      )
      attachment = deliver(archive, name: 'response.zip',
                                    type: 'application/zip')
      expect(Disclosures::SpreadsheetHold.waiting?(attachment)).to be(true)

      sign_in(owner)
      download(attachment)
      expect(response).not_to have_http_status(:ok)

      analyse(attachment)
      expect(attachment.prominence).not_to eq('hidden')
      expect(Disclosures::SpreadsheetHold.waiting?(attachment)).to be(false)
      download(attachment)
      expect(response).to have_http_status(:ok)
    end

    it 'holds a .zip carrying a suspect .xlsx or legacy .xls' do
      [
        ['bundle-xlsx.zip',
         OfficeFixtures.package({ 'data/suspect.xlsx' => hidden_data })],
        ['bundle-xls.zip',
         OfficeFixtures.package({ 'legacy.xls' => suspect_xls })],
        ['bundle-nested.zip',
         OfficeFixtures.package(
           { 'inner.zip' => OfficeFixtures.package(
             { 'deep.xlsx' => hidden_data }
           ) }
         )]
      ].each do |filename, archive|
        attachment = deliver(archive, name: filename, type: 'application/zip')
        analyse(attachment)
        expect(attachment.prominence).to eq('hidden'), filename
      end
    end

    it 'blocks .docx download while waiting, releases clean docs, and holds ' \
       'one with a suspect embedded spreadsheet' do
      clean_docx = OfficeFixtures.word(
        '<w:p><w:r><w:t>Plain letter</w:t></w:r></w:p>'
      )
      clean = deliver(clean_docx, name: 'letter.docx', type: docx_type)
      expect(Disclosures::SpreadsheetHold.waiting?(clean)).to be(true)
      analyse(clean)
      expect(Disclosures::SpreadsheetHold.waiting?(clean.reload)).to be(false)
      expect(clean.prominence).not_to eq('hidden')

      [
        ['with-xlsx.docx',
         OfficeFixtures.word(
           '<w:p><w:r><w:t>Chart</w:t></w:r></w:p>',
           parts: { 'word/embeddings/chart1.xlsx' => [nil, hidden_data] }
         )],
        ['with-xls.docx',
         OfficeFixtures.word(
           '<w:p><w:r><w:t>Legacy</w:t></w:r></w:p>',
           parts: { 'word/embeddings/legacy.xls' => [nil, suspect_xls] }
         )]
      ].each do |filename, bytes|
        attachment = deliver(bytes, name: filename, type: docx_type)
        expect(Disclosures::SpreadsheetHold.waiting?(attachment)).to be(true)
        analyse(attachment)
        expect(attachment.prominence).to eq('hidden'), filename
      end
    end

    it 'holds a clean .xlsx that embeds a suspect spreadsheet' do
      zip_with_embed = Tempfile.create(['embed', '.xlsx']) do |file|
        file.binmode
        file.write(clean_xlsx)
        file.flush
        Zip::File.open(file.path) do |zip|
          zip.get_output_stream('xl/embeddings/inner.xlsx') do |io|
            io.write(hidden_data)
          end
        end
        File.binread(file.path)
      end
      attachment = deliver(zip_with_embed, name: 'outer.xlsx', type: xlsx_type)
      analyse(attachment)
      expect(attachment.prominence).to eq('hidden')
    end

    it 'caps total legacy .xls conversions across embedded files inside a zip' do
      calls = 0
      clean_bytes = clean_xlsx
      allow_any_instance_of(ExcelAnalyzer::XlsAnalyzer).
        to receive(:convert) do
          calls += 1
          Tempfile.new(['clean', '.xlsx']).tap do |tf|
            tf.binmode
            tf.write(clean_bytes)
            tf.rewind
          end
        end

      parts = (1..4).to_h do |i|
        ["word/embeddings/s#{i}.xls", [nil, suspect_xls]]
      end
      docx = OfficeFixtures.word('<w:p/>', parts: parts)
      archive = OfficeFixtures.package((1..4).to_h { |i| ["d#{i}.docx", docx] })
      attachment = deliver(archive, name: 'many-xls.zip',
                                    type: 'application/zip')
      analyse(attachment)
      expect(calls).to eq(ExcelAnalyzer::ZipAnalyzer::MAX_XLS)
      expect(attachment.prominence).to eq('hidden')
    end

    it 'short-circuits zip scanning once a suspect spreadsheet is found' do
      expect_any_instance_of(ExcelAnalyzer::XlsAnalyzer).
        not_to receive(:convert)

      archive = OfficeFixtures.package(
        { '01-suspect.xlsx' => hidden_data, '02-legacy.xls' => suspect_xls }
      )
      attachment = deliver(archive, name: 'short.zip', type: 'application/zip')
      analyse(attachment)
      expect(attachment.prominence).to eq('hidden')
    end

    it 'holds a zip with a skipped spreadsheet entry but ignores a skipped ' \
       'non-spreadsheet' do
      stub_const('ExcelAnalyzer::ZipAnalyzer::MAX_ENTRY', 100)

      pdf_zip = OfficeFixtures.package({ 'big.pdf' => 'x' * 300 })
      clean_att = deliver(pdf_zip, name: 'pdfs.zip', type: 'application/zip')
      analyse(clean_att)
      expect(clean_att.prominence).not_to eq('hidden')

      sheet_zip = OfficeFixtures.package({ 'big.xlsx' => clean_xlsx })
      held_att = deliver(sheet_zip, name: 'sheets.zip', type: 'application/zip')
      analyse(held_att)
      expect(held_att.prominence).to eq('hidden')
    end

    it 'holds a zip when entry or byte budget runs out right at a nested zip' do
      stub_const('ExcelAnalyzer::ZipAnalyzer::MAX_ENTRIES', 2)
      inner = OfficeFixtures.package({ 'hidden.xlsx' => hidden_data })
      archive = OfficeFixtures.package(
        { '01.txt' => 'a', '02.zip' => inner }
      )
      attachment = deliver(archive, name: 'exact-cap.zip',
                                    type: 'application/zip')
      analyse(attachment)
      expect(attachment.prominence).to eq('hidden')
    end

    it 'holds a zip when a nested zip exhausts the entry or byte budget ' \
       'before a later outer workbook' do
      stub_const('ExcelAnalyzer::ZipAnalyzer::MAX_ENTRIES', 5)
      inner = OfficeFixtures.package(
        (1..4).to_h { |i| ["note#{i}.txt", "x#{i}"] }
      )
      archive = OfficeFixtures.package(
        { '01-inside.zip' => inner, '02-secret.xlsx' => hidden_data }
      )
      attachment = deliver(archive, name: 'budget-entries.zip',
                                    type: 'application/zip')
      analyse(attachment)
      expect(attachment.prominence).to eq('hidden')

      stub_const('ExcelAnalyzer::ZipAnalyzer::MAX_ENTRIES', 500)
      byte_inner = OfficeFixtures.package({ 'pad.txt' => 'a' * 200 })
      stub_const('ExcelAnalyzer::ZipAnalyzer::MAX_TOTAL',
                 byte_inner.bytesize + 250)
      byte_archive = OfficeFixtures.package(
        { '01-inside.zip' => byte_inner, '02-secret.xlsx' => hidden_data }
      )
      byte_att = deliver(byte_archive, name: 'budget-bytes.zip',
                                       type: 'application/zip')
      analyse(byte_att)
      expect(byte_att.prominence).to eq('hidden')
    end

    it 'holds an encrypted .docx directly and inside a zip, but allows ' \
       'an unencrypted legacy .doc mislabelled as .docx' do
      encrypted = OfficeFixtures.compound(
        { 'EncryptionInfo' => 'enc', 'EncryptedPackage' => 'pkg' }
      )
      enc_docx = deliver(encrypted, name: 'locked.docx', type: docx_type)
      analyse(enc_docx)
      expect(enc_docx.prominence).to eq('hidden')

      enc_xlsx = deliver(encrypted, name: 'locked.xlsx', type: xlsx_type)
      analyse(enc_xlsx)
      expect(enc_xlsx.prominence).to eq('hidden')

      enc_zip = deliver(
        OfficeFixtures.package({ 'locked.docx' => encrypted }),
        name: 'locked.zip', type: 'application/zip'
      )
      analyse(enc_zip)
      expect(enc_zip.prominence).to eq('hidden')

      legacy_doc = OfficeFixtures.compound({ 'WordDocument' => 'plain' })
      old_doc = deliver(legacy_doc, name: 'legacy.docx', type: docx_type)
      analyse(old_doc)
      expect(old_doc.prominence).not_to eq('hidden')
    end

    it 'holds a .docx or .xlsx whose embedded workbook triggers named ' \
       'ranges and external links even when Presidio says the container is ' \
       'clear' do
      allow(AlaveteliConfiguration).to receive(:disclosures_pii_check).
        and_return('presidio')
      allow(AlaveteliConfiguration).
        to receive(:disclosures_pii_check_endpoint).
        and_return('http://127.0.0.1:5002')
      stub_request(:post, 'http://127.0.0.1:5002/analyze').
        to_return(status: 200, body: [].to_json,
                  headers: { 'Content-Type' => 'application/json' })

      links_and_names = <<~XML
        <definedNames><definedName name="People">Sheet1!$A$1</definedName></definedNames>
        <externalReferences><externalReference r:id="rIdExt1"/></externalReferences>
      XML
      inner_wb = OfficeFixtures.workbook(
        sheets: {
          'xl/worksheets/sheet1.xml' =>
            OfficeFixtures.sheet_xml([['Name', 'jane@example.org']])
        },
        workbook_extra: links_and_names, core: nil
      )

      docx = OfficeFixtures.word(
        '<w:p><w:r><w:t>Public summary</w:t></w:r></w:p>',
        parts: { 'word/embeddings/chart.xlsx' => [nil, inner_wb] }
      )
      docx_att = deliver(docx, name: 'summary.docx', type: docx_type)
      analyse(docx_att)
      expect(docx_att.prominence).to eq('hidden')

      outer_wb = Tempfile.create(['outer-embed', '.xlsx']) do |file|
        file.binmode
        file.write(clean_xlsx)
        file.flush
        Zip::File.open(file.path) do |zip|
          zip.get_output_stream('xl/embeddings/inner.xlsx') do |io|
            io.write(inner_wb)
          end
        end
        File.binread(file.path)
      end
      xlsx_att = deliver(outer_wb, name: 'outer.xlsx', type: xlsx_type)
      analyse(xlsx_att)
      expect(xlsx_att.prominence).to eq('hidden')
    end

    it 'holds a .docx with a relationship-linked workbook outside ' \
       '/embeddings/ or an OOXML workbook inside an OLE2 Package stream' do
      rel_docx = OfficeFixtures.word(
        '<w:p><w:r><w:t>Report</w:t></w:r></w:p>',
        document_rels: [['rIdPkg1', "#{OfficeFixtures::R}package",
                         'custom/sheet.bin']],
        parts: { 'word/custom/sheet.bin' =>
                 ['application/octet-stream', hidden_data] }
      )
      rel_att = deliver(rel_docx, name: 'linked.docx', type: docx_type)
      analyse(rel_att)
      expect(rel_att.prominence).to eq('hidden')

      ole_pkg = OfficeFixtures.compound({ 'Package' => hidden_data })
      ole_docx = OfficeFixtures.word(
        '<w:p><w:r><w:t>Embedded OLE</w:t></w:r></w:p>',
        parts: { 'word/embeddings/oleObject1.bin' => [nil, ole_pkg] }
      )
      ole_att = deliver(ole_docx, name: 'ole-pkg.docx', type: docx_type)
      analyse(ole_att)
      expect(ole_att.prominence).to eq('hidden')
    end

    it 'probes zip spreadsheet entries even with trailing spaces or dots' do
      ['secret.xlsx ', 'secret.xlsx.', '.xlsx'].each_with_index do |name, idx|
        archive = OfficeFixtures.package({ name => hidden_data })
        att = deliver(archive, name: "padded-#{idx}.zip",
                               type: 'application/zip')
        analyse(att)
        expect(att.prominence).to eq('hidden'), name
      end
    end

    it 'holds encrypted or truncated OLE2 .xls, misnamed .xlsx as .docx, ' \
       'and truncated ZIP .docx files' do
      encrypted = OfficeFixtures.compound(
        { 'EncryptionInfo' => 'enc', 'EncryptedPackage' => 'pkg' }
      )
      [
        ['locked.xls', ExcelAnalyzer::OLE2_CONTENT_TYPE, encrypted],
        ['trunc.xls', ExcelAnalyzer::XlsAnalyzer::CONTENT_TYPE,
         suspect_xls[0, 600]],
        ['misnamed.docx', docx_type, hidden_data],
        ['broken.docx', docx_type, hidden_data[0, 100]]
      ].each do |fname, ctype, bytes|
        att = deliver(bytes, name: fname, type: ctype)
        analyse(att)
        expect(att.prominence).to eq('hidden'), fname
      end
    end
  end

  describe 'when the Office cell refuses a scan' do
    let(:clean_xlsx) { File.binread(fixtures.join('data.xlsx')) }

    it 'leaves .xlsx waiting without holding or emailing, then recovers' do
      clean = deliver(clean_xlsx, name: 'clean.xlsx')
      suspect = deliver(hidden_data, name: 'suspect.xlsx')

      allow(OfficePackage::Isolated).to receive(:read).
        and_raise(AlaveteliSandbox::Refused, 'office cell unavailable')
      ActionMailer::Base.deliveries.clear

      [clean, suspect].each do |att|
        expect { analyse(att) }.not_to raise_error
        expect(att.file_blob.reload).not_to be_analyzed
        expect(Disclosures::SpreadsheetHold.waiting?(att)).to be(true)
        expect(att.prominence).not_to eq('hidden')
      end
      expect(ActionMailer::Base.deliveries).to be_empty

      sign_in(owner)
      download(clean)
      expect(response).not_to have_http_status(:ok)

      allow(OfficePackage::Isolated).to receive(:read).and_call_original
      perform_enqueued_jobs(only: ActiveStorage::AnalyzeJob) do
        Disclosures::SpreadsheetCheckJob.perform_now(clean.incoming_message_id)
        Disclosures::SpreadsheetCheckJob.perform_now(suspect.incoming_message_id)
      end

      expect(Disclosures::SpreadsheetHold.waiting?(clean.reload)).to be(false)
      expect(clean.prominence).not_to eq('hidden')
      expect(suspect.reload.prominence).to eq('hidden')
    end

    it 'leaves legacy .xls waiting when LibreOffice is refused' do
      xls = deliver(File.binread(fixtures.join('data.xls')),
                    name: 'legacy.xls',
                    type: ExcelAnalyzer::XlsAnalyzer::CONTENT_TYPE)
      allow(AlaveteliSandbox).to receive(:job).
        and_raise(AlaveteliSandbox::Refused, 'office cell unavailable')
      ActionMailer::Base.deliveries.clear

      expect { analyse(xls) }.not_to raise_error
      expect(xls.file_blob.reload).not_to be_analyzed
      expect(Disclosures::SpreadsheetHold.waiting?(xls)).to be(true)
      expect(xls.prominence).not_to eq('hidden')
      expect(ActionMailer::Base.deliveries).to be_empty
    end

    it 'still holds immediately on a per-file timeout' do
      attachment = deliver(clean_xlsx, name: 'slow.xlsx')
      allow(OfficePackage::Isolated).to receive(:read).
        and_raise(AlaveteliSandbox::TimedOut, 'office-worker timed out')

      analyse(attachment)
      expect(attachment.file_blob.reload).to be_analyzed
      expect(attachment.prominence).to eq('hidden')
    end

    it 'leaves .docx waiting when the Office cell or LibreOffice refuses' do
      docx_type =
        'application/vnd.openxmlformats-officedocument.' \
        'wordprocessingml.document'
      clean_docx = OfficeFixtures.word('<w:p><w:r><w:t>Hi</w:t></w:r></w:p>')
      clean = deliver(clean_docx, name: 'letter.docx', type: docx_type)
      with_xls = deliver(
        OfficeFixtures.word(
          '<w:p/>',
          parts: { 'word/embeddings/s.xls' =>
                   [nil, File.binread(fixtures.join('suspect.xls'))] }
        ),
        name: 'chart.docx', type: docx_type
      )

      allow(OfficePackage::Isolated).to receive(:read).
        and_raise(AlaveteliSandbox::Refused, 'office cell unavailable')
      ActionMailer::Base.deliveries.clear

      expect { analyse(clean) }.not_to raise_error
      expect(clean.file_blob.reload).not_to be_analyzed
      expect(Disclosures::SpreadsheetHold.waiting?(clean)).to be(true)
      expect(clean.prominence).not_to eq('hidden')

      allow(OfficePackage::Isolated).to receive(:read).and_call_original
      allow(AlaveteliSandbox).to receive(:job).
        and_raise(AlaveteliSandbox::Refused, 'office cell unavailable')

      expect { analyse(with_xls) }.not_to raise_error
      expect(with_xls.file_blob.reload).not_to be_analyzed
      expect(Disclosures::SpreadsheetHold.waiting?(with_xls)).to be(true)
      expect(with_xls.prominence).not_to eq('hidden')
      expect(ActionMailer::Base.deliveries).to be_empty

      allow(AlaveteliSandbox).to receive(:job).and_call_original
      perform_enqueued_jobs(only: ActiveStorage::AnalyzeJob) do
        Disclosures::SpreadsheetCheckJob.perform_now(clean.incoming_message_id)
        Disclosures::SpreadsheetCheckJob.perform_now(
          with_xls.incoming_message_id
        )
      end

      expect(Disclosures::SpreadsheetHold.waiting?(clean.reload)).to be(false)
      expect(clean.prominence).not_to eq('hidden')
      expect(with_xls.reload.prominence).to eq('hidden')
    end

    it 'leaves .zip waiting when outer or inner scan is refused, then recovers' do
      archive = OfficeFixtures.package({ 'clean.xlsx' => clean_xlsx })
      att = deliver(archive, name: 'bundle.zip', type: 'application/zip')
      ActionMailer::Base.deliveries.clear

      allow(OfficePackage::Isolated).to receive(:read_zip).
        and_raise(AlaveteliSandbox::Refused, 'office cell unavailable')
      expect { analyse(att) }.not_to raise_error
      expect(att.file_blob.reload).not_to be_analyzed
      expect(att.prominence).not_to eq('hidden')

      allow(OfficePackage::Isolated).to receive(:read_zip).and_call_original
      allow(OfficePackage::Isolated).to receive(:read).
        and_raise(AlaveteliSandbox::Refused, 'office cell unavailable')
      expect { analyse(att) }.not_to raise_error
      expect(att.file_blob.reload).not_to be_analyzed
      expect(att.prominence).not_to eq('hidden')
      expect(ActionMailer::Base.deliveries).to be_empty

      allow(OfficePackage::Isolated).to receive(:read).and_call_original
      perform_enqueued_jobs(only: ActiveStorage::AnalyzeJob) do
        Disclosures::SpreadsheetCheckJob.perform_now(att.incoming_message_id)
      end
      expect(Disclosures::SpreadsheetHold.waiting?(att.reload)).to be(false)
      expect(att.prominence).not_to eq('hidden')
    end

    it 'blocks requester download and retries generic OLE Office files ' \
       'during a cell outage, while ignoring non-Office OLE files' do
      ole_type = ExcelAnalyzer::OLE2_CONTENT_TYPE
      encrypted = OfficeFixtures.compound(
        { 'EncryptionInfo' => 'enc', 'EncryptedPackage' => 'pkg' }
      )
      clear_enqueued_jobs
      ole_docx = deliver(encrypted, name: 'locked.docx', type: ole_type)
      expect(Disclosures::SpreadsheetCheckJob).
        to have_been_enqueued.with(ole_docx.incoming_message_id)
      expect(Disclosures::SpreadsheetHold.waiting?(ole_docx)).to be(true)

      ole_msg = deliver(
        OfficeFixtures.compound({ 'WordDocument' => 'plain' }),
        name: 'note.msg', type: ole_type
      )
      expect(Disclosures::SpreadsheetHold.waiting?(ole_msg)).to be(false)
      expect(Disclosures::SpreadsheetHold.unread).to include(ole_docx)
      expect(Disclosures::SpreadsheetHold.unread).not_to include(ole_msg)

      allow(OfficePackage::Isolated).to receive(:read).
        and_raise(AlaveteliSandbox::Refused, 'office cell unavailable')
      expect { analyse(ole_docx) }.not_to raise_error
      expect(ole_docx.file_blob.reload).not_to be_analyzed
      expect(Disclosures::SpreadsheetHold.waiting?(ole_docx)).to be(true)

      sign_in(owner)
      download(ole_docx)
      expect(response).not_to have_http_status(:ok)

      allow(OfficePackage::Isolated).to receive(:read).and_call_original
      perform_enqueued_jobs(only: ActiveStorage::AnalyzeJob) do
        Disclosures::SpreadsheetCheckJob.
          perform_now(ole_docx.incoming_message_id)
      end
      expect(ole_docx.reload.prominence).to eq('hidden')
    end
  end
end
