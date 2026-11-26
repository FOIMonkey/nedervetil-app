require 'spec_helper'

RSpec.describe IncomingMessage, 'header values' do
  let(:request) { FactoryBot.create(:info_request) }

  let(:columns) do
    %w[sent_at subject from_name from_email from_email_domain
       valid_to_reply_to]
  end

  def received(source, by: request)
    by.receive(Mail.from_source(source), override_stop_new_responses: true)
  end

  describe 'when mail is received' do
    let(:message) do
      received(<<~EML)
        From: Records Team <records@authority.example>
        To: #{request.incoming_email}
        Subject: Your request
        Date: Mon, 2 Nov 2026 10:15:00 +0000

        Hello
      EML
    end

    it 'stores them without parsing the mail' do
      stored = described_class.find(message.id)

      expect(stored[:last_parsed]).to be_nil
      expect(stored.foi_attachments).to be_empty
      expect(stored.attributes.slice(*columns)).to eq(
        'sent_at' => Time.utc(2026, 11, 2, 10, 15),
        'subject' => 'Your request',
        'from_name' => 'Records Team',
        'from_email' => 'records@authority.example',
        'from_email_domain' => 'authority.example',
        'valid_to_reply_to' => true
      )
    end

    it 'dates a mail with no Date header by when it arrived' do
      message = received("From: a@authority.example\n\nHello\n")

      expect(message[:sent_at]).to eq(message.created_at)
    end

    it 'still receives a mail whose header lines cannot be read' do
      allow(MailHandler).to receive(:get_subject).and_raise(ArgumentError)

      stored = described_class.find(message.id)

      expect(stored.attributes.slice(*columns).values).to all(be_nil)
      expect(request.incoming_messages).to eq([stored])
    end

    # A null byte is refused before the database sees it; a date past what
    # it stores is refused by the database, inside the transaction.
    { 'a subject with a null byte' => 'Subject: =?UTF-8?B?AA==?=',
      'a date the database cannot store' =>
        'Date: Mon, 2 Nov 999999 10:15:00 +0000' }.each do |what, header|
      it "still receives a mail with #{what}" do
        message = received(<<~EML)
          From: Records Team <records@authority.example>
          #{header}

          Hello
        EML

        stored = described_class.find(message.id)
        expect(stored.attributes.slice(*columns).values).to all(be_nil)
        expect(message.changed?).to be(false)
        expect(request.incoming_messages).to eq([stored])
        expect(request.info_request_events.last.event_type).to eq('response')
      end
    end

    it 'stores what a parse of the same mail stores, for every fixture' do
      differing = Dir[file_fixture_name('*.eml')].filter_map do |path|
        message = received(File.binread(path),
                           by: FactoryBot.create(:info_request))
        at_receipt = message.reload.attributes.slice(*columns)
        message.parse_raw_email!
        parsed = message.reload.attributes.slice(*columns)
        [File.basename(path), at_receipt, parsed] unless at_receipt == parsed
      end

      expect(differing).to eq([])
    end
  end

  describe 'a reply with none stored' do
    let(:message) do
      FactoryBot.create(:incoming_message, :unparsed, info_request: request)
    end

    before do
      message.raw_email.data = +<<~EML
        From: Records Team <records@authority.example>
        Subject: An older reply
        Date: Mon, 2 Nov 2026 10:15:00 +0000

        Hello
      EML
      message.raw_email.save!
      allow(MailHandler).to receive(:get_attachment_attributes)
    end

    %i[sent_at subject from_name from_email from_email_domain
       valid_to_reply_to].each do |name|
      it "reads and stores them when asked for #{name}, parsing nothing" do
        message.public_send(name)

        stored = described_class.find(message.id)
        expect(stored.attributes.slice(*columns)).to eq(
          'sent_at' => Time.utc(2026, 11, 2, 10, 15),
          'subject' => 'An older reply',
          'from_name' => 'Records Team',
          'from_email' => 'records@authority.example',
          'from_email_domain' => 'authority.example',
          'valid_to_reply_to' => true
        )
        expect(stored[:last_parsed]).to be_nil
        expect(MailHandler).not_to have_received(:get_attachment_attributes)
      end
    end

    it 'reads the mail for the first value asked for only' do
      message.subject
      allow(message.raw_email).to receive(:mail)

      message.from_name
      message.sent_at

      expect(message.raw_email).not_to have_received(:mail)
    end

    it 'raises when the mail has been erased' do
      allow(message.raw_email).to receive(:erased?).and_return(true)

      expect { message.subject }.to raise_error(RawEmail::ErasedError)
    end

    it 'raises when there is no mail' do
      expect { described_class.new.subject }.
        to raise_error(/has no raw_email/)
    end
  end

  describe 'a parsed reply' do
    it 'keeps the values the parse stored' do
      message = FactoryBot.create(:incoming_message, info_request: request)
      allow(message.raw_email).to receive(:mail)

      message.subject
      message.from_email

      expect(message.raw_email).not_to have_received(:mail)
    end
  end
end
