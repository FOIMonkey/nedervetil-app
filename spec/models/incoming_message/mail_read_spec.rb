require 'spec_helper'

RSpec.describe IncomingMessage, 'reading its mail' do
  include MailReadHelpers
  include UuencodedMail

  let(:info_request) { FactoryBot.create(:info_request) }
  let(:message) do
    receive_incoming_mail('incoming-request-two-same-name.eml',
                          to: info_request.incoming_email)
    info_request.incoming_messages.last
  end
  let(:outside) { ActiveRecord::Base.connection.open_transactions }

  def stored(message)
    IncomingMessage.where(id: message.id).
      pick(:last_parsed, :cached_main_body_text_folded)
  end

  def parts_stored(message)
    FoiAttachment.where(incoming_message_id: message.id).count
  end

  describe '#parse_raw_email!' do
    it 'reads the mail once, before it takes the parsing lock, a ' \
       'transaction or a row lock' do
      message
      reads = watch_mail_reads

      message.parse_raw_email!

      expect(reads).to eq(
        [{ options: {}, transactions: outside, advisory_locks: 0 }]
      )
      expect(parts_stored(message)).to eq(3)
      expect(stored(message).first).to be_present
    end

    it 'stores nothing when the read is refused' do
      message
      refuse_mail_reads

      expect { message.parse_raw_email! }.
        to raise_error(MailHandler::ReadRefused)
      expect { message.parse_raw_email }.
        to raise_error(MailHandler::ReadRefused)
      expect(stored(message)).to eq([nil, nil])
      expect(parts_stored(message)).to eq(0)
    end

    # The other parse's files may still be storing when its row is
    # committed, so its locks are waited for all the same.
    it 'does not read a reply another process has parsed, and still takes ' \
       'the parsing lock' do
      message
      IncomingMessage.find(message.id).parse_raw_email!
      expect(MailHandler::Reading).not_to receive(:of)
      expect(IncomingMessage::ParsingLock).
        to receive(:synchronize).once.and_call_original

      expect(message.last_parsed).to be_nil
      message.parse_raw_email
      expect(message.last_parsed).to be_present
      expect(message.foi_attachments.size).to eq(3)
    end

    it 'reads and stores after all when the reply turns out not to be ' \
       'parsed' do
      message
      allow(message).to receive(:parsed_already?).and_return(true)
      reads = watch_mail_reads

      message.parse_raw_email

      # With no row lock held. (The parsing lock taken to look is kept to
      # the end of the example's own transaction.)
      expect(reads.map { |read| read.slice(:options, :transactions) }).
        to eq([{ options: {}, transactions: outside }])
      expect(parts_stored(message)).to eq(3)
    end

    it 'throws its reading away when another parse finished while it read' do
      message
      watch_mail_reads do
        IncomingMessage.where(id: message.id).
          update_all(last_parsed: Time.zone.now)
      end

      message.parse_raw_email
      expect(message.last_parsed).to be_present
      expect(parts_stored(message)).to eq(0)
    end

    it 'queues no check of spreadsheets when the read was ' \
       'refused: nothing has changed' do
      message
      refuse_mail_reads
      expect(FoiAttachment::SpreadsheetHold).not_to receive(:check_later)

      expect { message.parse_raw_email! }.
        to raise_error(MailHandler::ReadRefused)
    end

    it 'queues spreadsheet checks when the parse fails after the read' do
      message
      allow(message).to receive(:extract_attachments).and_raise('Stopped')
      expect(FoiAttachment::SpreadsheetHold).
        to receive(:check_later).with(message)

      expect { message.parse_raw_email! }.to raise_error('Stopped')
    end

    it 'stores nothing when the email was erased while it was read' do
      message
      watch_mail_reads do
        RawEmail.where(id: message.raw_email.id).
          update_all(erased_at: Time.zone.now)
      end

      expect { message.parse_raw_email! }.
        to raise_error(RawEmail::Erasable::ErasedError)
      expect(stored(message)).to eq([nil, nil])
      expect(parts_stored(message)).to eq(0)
    end

    describe 'of a reply already parsed, whose email has no stored file' do
      def kept
        FoiAttachment.where(incoming_message_id: message.id).order(:id).
          map { |part| [part.id, part.hexdigest, part.file.download] }
      end

      let(:without_its_file) do
        message.parse_raw_email!
        ActiveStorage::Attachment.where(record: message.raw_email).delete_all
        IncomingMessage.find(message.id)
      end

      # No file is not an empty mail: read as one, the reply would be left
      # with a single empty part in place of its own.
      it 'raises, and keeps every part and its file' do
        expect(without_its_file.raw_email.data).to be_nil
        parts = kept

        expect { without_its_file.parse_raw_email! }.
          to raise_error(RawEmail::Erasable::ErasedError)
        expect(parts.size).to eq(3)
        expect(kept).to eq(parts)
      end

      it 'keeps reading stored files without re-reading the raw email' do
        without_its_file.info_request.expire
        parts = kept
        expect(parts.size).to eq(3)

        expect(FoiAttachment.find(parts.first.first).body).
          to eq(parts.first.last)
        expect(kept).to eq(parts)
      end
    end

    it 'holds a mail past the part limits, hidden, and marks it parsed' do
      message
      allow(MailHandler::Reading).to receive(:of).
        and_raise(MailHandler::TooComplex, 'mail part limit exceeded')

      message.parse_raw_email!

      expect(message.reload.prominence).to eq('hidden')
      expect(message.last_parsed).to be_present
      expect(parts_stored(message)).to eq(0)
    end

    describe 'of a mail with uuencoded attachments in its text' do
      let(:limit) { MailHandler::MAX_UU_BLOCKS }

      def received(*parts)
        info_request.receive(Mail.from_source(uuencoded_mail(*parts)))
      end

      it 'takes the main text’s, however many the parts after it hold' do
        message = received(['text/plain', 2], ['text/csv', limit],
                           ['text/x-log', 3])

        message.parse_raw_email!

        expect(message.reload.prominence).to eq('normal')
        expect(message.foi_attachments.map(&:filename)).
          to include('file-1.txt', 'file-2.txt')
        expect(parts_stored(message)).to eq(5)
      end

      it 'holds a mail whose main text comes after as many of them as ' \
         'the limit, hidden, with none of its parts kept' do
        message = received(['text/csv', limit], ['text/plain', 2])

        message.parse_raw_email!

        expect(message.reload.prominence).to eq('hidden')
        expect(message.last_parsed).to be_present
        expect(parts_stored(message)).to eq(0)
        expect(info_request.info_request_events.last.params[:reason]).to eq(
          'Mail not processed: as many uuencoded blocks as a mail may ' \
          'hold come before the main text'
        )
      end
    end

    it 'leaves the values from the header lines as they were stored at ' \
       'receipt' do
      message
      IncomingMessage.where(id: message.id).update_all(subject: 'As stored')

      IncomingMessage.find(message.id).parse_raw_email!

      expect(message.reload.subject).to eq('As stored')
    end
  end

  describe 'shown while its mail can’t be read' do
    before do
      message
      refuse_mail_reads
      allow(Rails.logger).to receive(:warn)
    end

    it 'is not parsed for display, and says why in the log' do
      expect(message.parsed_for_display?).to be(false)
      expect(Rails.logger).to have_received(:warn).
        with(/IncomingMessage #{message.id}: shown unread \(the mail cell/)
    end

    it 'lists no attachments' do
      expect(message.get_attachments_for_display).to eq([])
    end

    it 'asks for the mail to be read once, however often it is shown' do
      message.parsed_for_display?
      message.get_attachments_for_display
      message.get_main_body_text_folded
      message.get_body_for_html_display

      expect(MailHandler::Reading).to have_received(:of).once
    end

    it 'shows the note where its text would be' do
      expect(message.get_main_body_text_folded).
        to include('We were not able to process this message')
      expect(message.get_body_for_html_display).
        to include('We were not able to process this message')
    end

    it 'still says who sent it and when, from what was stored at receipt' do
      expect(message.from_email).to eq('geraldinequango@localhost')
      expect(message.sent_at).to be_present
    end

    it 'stores none of that, so the text and attachments appear once the ' \
       'mail is read' do
      message.get_attachments_for_display
      message.get_main_body_text_folded
      expect(stored(message)).to eq([nil, nil])
      expect(parts_stored(message)).to eq(0)

      allow_mail_reads
      shown = IncomingMessage.find(message.id)
      expect(shown.get_attachments_for_display.map(&:filename)).
        to eq(%w[hello-world.txt hello-world.txt])
      expect(shown.get_main_body_text_folded).
        not_to include('not able to process')
      expect(stored(message).first).to be_present
      expect(stored(message).last).not_to be_nil
    end
  end
end
