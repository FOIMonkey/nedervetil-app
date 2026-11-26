require 'spec_helper'
require 'zip'

RSpec.describe 'Background jobs' do
  include ActiveJob::TestHelper

  describe 'email analysis' do
    def email_blob(service)
      ActiveStorage::Blob.create_and_upload!(
        io: StringIO.new("Subject: Synthetic\r\n\r\nSynthetic body\r\n"),
        filename: 'message.eml',
        content_type: 'message/rfc822',
        service_name: service,
        identify: false
      )
    end

    it 'skips the inbound copy of an email, and still reads the raw copy' do
      inbound = email_blob(ActionMailbox.storage_service.to_s)
      raw = email_blob('raw_emails')
      expect(ExcelAnalyzer::EmlAnalyzer.accept?(inbound)).to be false
      expect(ExcelAnalyzer::EmlAnalyzer.accept?(raw)).to be true

      allow(MailHandler::Reading).to receive(:of).and_call_original
      [inbound, raw].each(&:analyze)
      expect(MailHandler::Reading).to have_received(:of).once
      expect([inbound, raw].map { |blob| blob.reload.metadata['analyzed'] }).
        to all(be true)
    end
  end

  describe 'hidden spreadsheet columns' do
    def metadata(rows:, cols:)
      sheet = DocumentFixtures.xlsx(
        sheets: [
          {
            name: 'Data',
            rows: [%w[Ref Area Count Cost Note]] +
                  Array.new(rows) { |i|
                    ["R#{i}", "Area #{i % 40}", i % 97, i * 13, "n#{i % 11}"]
                  }
          }
        ]
      )
      out = Zip::OutputStream.write_buffer do |zip|
        Zip::File.open_buffer(StringIO.new(sheet)) do |source|
          source.each do |entry|
            data = entry.get_input_stream.read
            if entry.name == 'xl/worksheets/sheet1.xml'
              data = data.sub('<sheetData>', "<cols>#{cols}</cols><sheetData>")
            end
            zip.put_next_entry(entry.name)
            zip.write(data)
          end
        end
      end
      Tempfile.create(['hidden', '.xlsx']) do |file|
        file.binmode
        file.write(out.string)
        file.flush
        Zip::File.open(file.path) do |zip|
          yield ExcelAnalyzer::Metadata.new(zip)
        end
      end
    end

    def hidden(min, max)
      %(<col min="#{min}" max="#{max}" width="9" hidden="1"/>)
    end

    it 'counts each filled hidden column once, deduplicating overlapping ranges' do
      { hidden(13, 16_384) => 0,
        hidden(2, 3) => 2,
        hidden(2, 3) + hidden(3, 4) => 3,
        hidden(5, 7) => 1 }.each do |cols, count|
        metadata(rows: 30, cols: cols) do |meta|
          expect(meta.to_h[:hidden_columns]).to eq(count), cols
        end
      end
    end

    it 'reads the rows once, not once per hidden column' do
      metadata(rows: 5_000, cols: hidden(13, 16_384)) do |meta|
        started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        expect(meta.to_h[:hidden_columns]).to eq(0)
        expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).
          to be < 1.5
      end
    end
  end

  describe 'masking a part again' do
    let(:info_request) { FactoryBot.create(:info_request) }
    let(:attachment) do
      message = AttachmentFixtures.deliver(
        info_request,
        [['runs.txt', 'text/plain', "Gritting runs by ward\n"]]
      )
      message.get_attachments_for_display.first.tap(&:body)
    end

    it 'skips a queued job when another path has masked the part since it was queued' do
      attachment.update_columns(masked_at: nil)
      travel_to(10.seconds.ago) do
        FoiAttachment::MaskJob.perform_later(attachment)
      end
      travel_to(2.seconds.ago) { attachment.reload.mask }
      masked_at = attachment.reload.masked_at
      perform_enqueued_jobs(only: FoiAttachment::MaskJob)
      expect(attachment.reload.masked_at).to eq(masked_at)
    end

    it 'masks again when asked while the part was already masked, or when run directly' do
      travel_to(10.seconds.ago) { attachment.reload.mask }
      masked_at = attachment.reload.masked_at
      attachment.mask_later
      perform_enqueued_jobs(only: FoiAttachment::MaskJob)
      expect(attachment.reload.masked_at).to be > masked_at

      travel_to(10.seconds.ago) { attachment.reload.mask }
      masked_at = attachment.reload.masked_at
      FoiAttachment::MaskJob.perform_now(attachment)
      expect(attachment.reload.masked_at).to be > masked_at
    end

    it 'masks a part an expiry unmasked' do
      queued = attachment
      travel_to(10.seconds.ago) { FoiAttachment::MaskJob.perform_later(queued) }
      info_request.reload.expire
      expect(queued.reload.masked_at).to be_nil
      perform_enqueued_jobs(only: FoiAttachment::MaskJob)
      expect(queued.reload).to be_masked
    end
  end

  describe 'clearing message caches on expire' do
    it 'clears every message of the request in one statement, without saving the request' do
      request = FactoryBot.create(:info_request)
      messages = FactoryBot.create_list(
        :incoming_message, 4, info_request: request
      )
      IncomingMessage.where(id: messages).
        update_all(cached_main_body_text_folded: 'folded',
                   cached_main_body_text_unfolded: 'unfolded')
      updates = []
      count = ->(*, payload) do
        if payload[:sql].match?(
          /\A\s*UPDATE "(incoming_messages|info_requests|public_bodies)"/
        )
          updates << payload[:sql]
        end
      end
      ActiveSupport::Notifications.subscribed(count, 'sql.active_record') do
        InfoRequest.find(request.id).expire
      end

      expect(updates.size).to eq(1)
      expect(updates.first).to start_with('UPDATE "incoming_messages"')
      expect(IncomingMessage.where(id: messages).
               pluck(:cached_main_body_text_folded,
                     :cached_main_body_text_unfolded).flatten.compact).
        to be_empty
    end
  end

  describe 'deadlocks' do
    it 'retries a deadlock five times and then fails, rather than retrying it as any other error' do
      stub_const('DeadlockSpecJob', Class.new(ApplicationJob) do
        def perform
          raise ActiveRecord::Deadlocked
        end
      end)
      DeadlockSpecJob.perform_later
      expect {
        5.times { perform_enqueued_jobs(only: DeadlockSpecJob) }
      }.to raise_error(ActiveRecord::Deadlocked)

      [ApplicationJob].each do |job|
        handler = job.rescue_handlers.reverse.find do |name, _|
          ActiveRecord::Deadlocked <= name.constantize
        end
        expect(handler.first).to eq('ActiveRecord::Deadlocked'), job.name
      end
    end
  end
end
