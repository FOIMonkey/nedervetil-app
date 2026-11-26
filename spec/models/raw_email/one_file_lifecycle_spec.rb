require 'spec_helper'

RSpec.describe 'One-file storage and 120-day email clock' do
  include ActiveJob::TestHelper

  let(:info_request) { FactoryBot.create(:info_request) }

  def receive_reply(body:, content_type: 'text/plain', attachment: nil,
                    message_id: "<#{SecureRandom.hex(8)}@example.test>",
                    message_checksum: SecureRandom.hex(20))
    mail = Mail.new
    mail.from = info_request.public_body.request_email
    mail.to = info_request.incoming_email
    mail.subject = 'Response'
    mail.message_id = message_id
    if attachment
      mail.text_part = Mail::Part.new(
        content_type: "#{content_type}; charset=UTF-8",
        body: body
      )
      mail.add_file(filename: attachment[:filename],
                    content: attachment[:content])
    else
      mail.content_type = "#{content_type}; charset=UTF-8"
      mail.body = body
    end
    info_request.receive(Mail.from_source(mail.encoded),
                         message_id: message_id,
                         message_checksum: message_checksum)
  end

  describe 'read once and unified main body' do
    it 'stores main body as UTF-8 plain text, marks read_at, and forgets InboundEmail' do
      message_id = "<#{SecureRandom.hex(8)}@example.test>"
      raw_source = "From: authority@example.org\r\n" \
                   "To: #{info_request.incoming_email}\r\n" \
                   "Subject: Reply\r\nMessage-ID: #{message_id}\r\n" \
                   "Content-Type: text/html; charset=UTF-8\r\n\r\n" \
                   '<html><body><p>Hello <b>world</b> &amp; ' \
                   'Hobnob</p></body></html>'
      inbound = ActionMailbox::InboundEmail.create_and_extract_message_id!(raw_source)
      inbound.delivered!

      FactoryBot.create(:censor_rule, censorable: info_request,
                                      text: 'Hobnob', replacement: '[black]')
      FactoryBot.create(:censor_rule, :blue, censorable: info_request,
                                             text: 'world',
                                             replacement: '[blue]')

      message = info_request.receive(Mail.from_source(raw_source),
                                     message_id: inbound.message_id,
                                     message_checksum: inbound.message_checksum)

      expect {
        IncomingMessage::StoreTextJob.perform_now(message)
      }.to have_enqueued_job(RawEmail::ForgetInboundJob).with(message.raw_email)

      message.reload
      raw_email = message.raw_email.reload
      main_part = message.get_main_body_text_part

      expect(raw_email).to be_read
      expect(main_part.prominence).to eq('requester_only')
      expect(main_part.content_type).to eq('text/plain')
      expect(main_part.charset).to eq('UTF-8')
      expect(main_part).to be_black_masked
      expect(main_part.body).to include('[black]')
      expect(main_part.body).not_to include('Hobnob')
      expect(main_part.body).to include('world')
      expect(message.get_main_body_text_unfolded).to include('[black]')
      expect(message.get_main_body_text_unfolded).to include('world')

      RawEmail::ForgetInboundJob.perform_now(raw_email)
      expect(ActionMailbox::InboundEmail.exists?(inbound.id)).to be(false)
    end

    it 'never opens RawEmail during normal reads or masking after read_at' do
      message = receive_reply(
        body: 'Plain reply text with SecretWord',
        attachment: { filename: 'notes.txt', content: 'Attached SecretWord' }
      )
      IncomingMessage::StoreTextJob.perform_now(message)
      message.reload

      expect(message.raw_email).to be_read
      expect(message.raw_email).not_to receive(:data)
      expect(MailHandler::Reading).not_to receive(:of)
      allow_any_instance_of(RawEmail).to receive(:data).
        and_raise('RawEmail must not be opened after read_at')

      FactoryBot.create(:censor_rule, censorable: info_request,
                                      text: 'SecretWord', replacement: '[gone]')
      info_request.clear_attachment_masks!
      info_request.clear_in_database_caches!

      message.reload.foi_attachments.each do |attachment|
        FoiAttachment::MaskJob.perform_now(attachment)
        expect(attachment.reload.body).to include('[gone]')
        expect(attachment.body).not_to include('SecretWord')
        expect(attachment).to be_black_masked
      end

      expect(message.reload.get_body_for_html_display).to include('[gone]')
    end

    it 'does not set black_masked when only blue rules exist' do
      FactoryBot.create(:censor_rule, :blue, censorable: info_request,
                                             text: 'PublicOnly',
                                             replacement: '[blue]')
      message = receive_reply(body: 'Contains PublicOnly text')
      IncomingMessage::StoreTextJob.perform_now(message)

      main_part = message.reload.get_main_body_text_part
      expect(main_part).not_to be_black_masked
      expect(main_part.body).to include('PublicOnly')
    end
  end

  describe 'RawEmail::ForgetInboundJob' do
    it 'retries while the inbound email is still pending or processing' do
      raw_source = "From: a@example.org\r\nTo: b@example.org\r\n" \
                   "Subject: Hi\r\n\r\nBody"
      inbound = ActionMailbox::InboundEmail.create_and_extract_message_id!(raw_source)
      raw_email = FactoryBot.create(
        :raw_email, read_at: Time.current,
                    message_id: inbound.message_id,
                    message_checksum: inbound.message_checksum
      )

      inbound.pending!
      expect {
        RawEmail::ForgetInboundJob.new.perform(raw_email)
      }.to raise_error(RawEmail::ForgetInboundJob::StillRouting)

      inbound.delivered!
      RawEmail::ForgetInboundJob.new.perform(raw_email)
      expect(ActionMailbox::InboundEmail.exists?(inbound.id)).to be(false)
    end
  end

  describe '120-day last_activity_at clock and cleanup' do
    it 'purges RawEmail#file 120 days after last_activity_at and resets on activity' do
      message = receive_reply(body: 'Hello authority reply')
      IncomingMessage::StoreTextJob.perform_now(message)
      raw_email = message.raw_email.reload

      old_time = 121.days.ago
      info_request.update_column(:last_activity_at, old_time)
      expect(RawEmail.expired).to include(raw_email)

      # Sending a follow-up / chaser resets the clock.
      FactoryBot.create(:internal_review_request, info_request: info_request)
      expect(info_request.reload.last_activity_at).to be > 1.minute.ago
      expect(RawEmail.expired).not_to include(raw_email)

      # Moving a reply onto a request also resets the clock.
      other = FactoryBot.create(:info_request)
      other.update_column(:last_activity_at, old_time)
      message.update!(info_request: other)
      expect(other.reload.last_activity_at).to be > 1.minute.ago

      # Once 120 days elapse without activity, purge_expired! removes the file.
      other.update_column(:last_activity_at, 121.days.ago)
      perform_enqueued_jobs { RawEmail.purge_expired! }

      raw_email.reload
      expect(raw_email.file).not_to be_attached
      expect(raw_email).not_to be_kept
      expect(raw_email).to be_expired
      expect { raw_email.ensure_not_erased! }.
        to raise_error(RawEmail::Erasable::ErasedError)
    end

    it 'does not purge holding-pen emails' do
      holding_pen = InfoRequest.holding_pen_request
      message = holding_pen.receive(
        Mail.from_source("From: a@example.org\r\nTo: x@example.org\r\n" \
                         "Subject: Unmatched\r\n\r\nHello"),
        override_stop_new_responses: true
      )
      IncomingMessage::StoreTextJob.perform_now(message)
      holding_pen.update_column(:last_activity_at, 200.days.ago)

      expect(RawEmail.expired).not_to include(message.raw_email)
    end
  end
end
