require 'spec_helper'

RSpec.describe MailHandler::Parts do
  include MailHandler

  describe :get_part_file_name do
    it 'returns the part file name' do
      mail = get_fixture_mail('document-pdf.eml')
      part = mail.attachments.first
      expect(get_part_file_name(part)).to eq('tiny-example.pdf')
    end

    it 'returns nil if there is no file name' do
      mail = get_fixture_mail('document-pdf.eml')
      part = mail.parts.first
      expect(get_part_file_name(part)).to be_nil
    end

    it 'turns an invalid UTF-8 name into a valid one' do
      mail = get_fixture_mail('non-utf8-filename.eml')
      part = mail.attachments.first
      filename = get_part_file_name(part)
      expect(filename.valid_encoding?).to eq(true)
    end
  end

  describe :get_part_body do
    it 'returns the body of a part' do
      expected = <<-DOC
Here's a PDF attachment which has a document/pdf content-type,
when it really should be application/pdf.\n
      DOC
      mail = get_fixture_mail('document-pdf.eml')
      part = MailHandler.get_attachment_leaves(mail).first
      expect(get_part_body(part)).to eq(expected)
    end

    it 'returns unfrozen string' do
      mail = get_fixture_mail('empty-8bit.eml')
      part = MailHandler.get_attachment_leaves(mail).first
      expect(get_part_body(part).frozen?).to eq(false)
    end
  end

  describe '#mail_from_outlook' do
    before { allow(MailHandler).to receive(:outlook_as_mime) }

    it 'keeps a message whose sector chain loops unexpanded, without ' \
       'handing it to msgconvert' do
      bytes = OfficeFixtures.compound(
        { MailHandler::OUTLOOK_PROPERTIES => 'x' * 5000 }
      ).b
      fat_sector = bytes.unpack1('@76V')
      bytes[(fat_sector + 1) * 512, 4] = [0].pack('V')

      expect(mail_from_outlook(bytes)).to be_nil
      expect(MailHandler).not_to have_received(:outlook_as_mime)
    end

    it 'keeps bytes that aren\'t a compound file unexpanded' do
      expect(mail_from_outlook('not an outlook message')).to be_nil
      expect(MailHandler).not_to have_received(:outlook_as_mime)
    end

    it 'keeps a compound file that is no message unexpanded' do
      bytes = OfficeFixtures.compound({ 'WordDocument' => 'x' * 5000 }).b

      expect(mail_from_outlook(bytes)).to be_nil
      expect(MailHandler).not_to have_received(:outlook_as_mime)
    end

    it 'hands a compound file that holds a message to msgconvert' do
      bytes = OfficeFixtures.compound(
        { MailHandler::OUTLOOK_PROPERTIES => 'x' * 5000 }
      ).b
      allow(MailHandler).to receive(:outlook_as_mime).with(bytes).
        and_return("Subject: Converted\r\n\r\nHello\r\n")

      expect(mail_from_outlook(bytes).subject).to eq('Converted')
    end

    it 'keeps a message msgconvert cannot convert unexpanded' do
      bytes = OfficeFixtures.compound(
        { MailHandler::OUTLOOK_PROPERTIES => 'x' * 5000 }
      ).b

      expect(mail_from_outlook(bytes)).to be_nil
      expect(MailHandler).to have_received(:outlook_as_mime).with(bytes)
    end
  end

  describe '#get_within_rfc822_subject' do
    it 'returns nil for a nil subject' do
      leaf = double(within_rfc822_attachment: double(subject: nil))
      expect(get_within_rfc822_subject(leaf)).to be_nil
    end

    it 'returns valid UTF-8 for a non UTF-8 subject' do
      leaf = double(within_rfc822_attachment: double(subject: "FOI \x97 REQ"))
      encoding = get_within_rfc822_subject(leaf).force_encoding('UTF-8')
      expect(encoding.valid_encoding?).to eq(true)
    end
  end

  describe :expand_and_normalize_parts do
    context 'when given a multipart message' do
      it 'should return a Mail::PartsList' do
        mail = get_fixture_mail('incoming-request-oft-attachments.eml')
        expect(expand_and_normalize_parts(mail, mail).class).to eq(Mail::PartsList)
      end
    end

    it 'rejects excessive MIME nesting' do
      part = double('recursive multipart', multipart?: true)
      allow(part).to receive(:parts).and_return([part])
      expect { expand_and_normalize_parts(part, part) }.
        to raise_error(MailHandler::TooComplex, /nesting/)
    end

    it 'rejects too many MIME parts' do
      part = Mail.new
      expect { expand_and_normalize_parts(part, part, 0, parts: 1_000) }.
        to raise_error(MailHandler::TooComplex, /part limit/)
    end
  end

  describe :get_attachment_attributes do
    it 'keeps a filename supplied only in the Content-Type name parameter' do
      mail = get_fixture_mail('content-type-name-only-attachment.eml')
      filenames = get_attachment_attributes(mail).map { |a| a[:filename] }
      expect(filenames).to include('report.xlsm')
    end
  end

  describe '#decode_attached_part' do
    it 'keeps an Outlook part that cannot be converted as a binary ' \
       'attachment' do
      allow(MailHandler).to receive(:outlook_as_mime).and_return(nil)
      mail = get_fixture_mail('incoming-request-oft-attachments.eml')
      part = mail.parts.last

      decode_attached_part(part, mail)

      expect(part.rfc822_attachment).to be_nil
      expect(part.content_type).to eq('application/octet-stream')
    end

    it 'fails the parse when the Outlook converter could not run' do
      allow(MailHandler).to receive(:outlook_as_mime).
        and_raise(MailHandler::ReadRefused, 'refused')
      mail = get_fixture_mail('incoming-request-oft-attachments.eml')

      expect { decode_attached_part(mail.parts.last, mail) }.
        to raise_error(MailHandler::ReadRefused)
    end
  end

  describe '#blank_text?' do
    values = [
      nil, '', ' ', "\t\r\n", "\u00a0", "\u3000\u2028 ", 'a', ' a ',
      "\u00a0a", ''.b, " \n".b, "\xA0".b, "\xFF",
      ' '.encode('UTF-16LE'), "\u3000".encode('UTF-16BE'),
      'a'.encode('UTF-16LE')
    ]

    def outcome
      yield
    rescue StandardError => e
      e.class
    end

    values.each do |value|
      it "is ActiveSupport's blank? for #{value.inspect} " \
         "(#{value&.encoding})" do
        expect(outcome { blank_text?(value) }).
          to eq(outcome { value.blank? })
      end
    end
  end

  describe '#mail_from_source' do
    sources = {
      'a mail with LF line ends' => "Subject: a\n\nbody\n",
      'a mail with CRLF line ends' => "Subject: a\r\n\r\nbody\r\n",
      'a mail with a lone CR' => "Subject: a\n\nbo\rdy\n",
      'bytes that are no text' => "Subject: a\n\n\xFF\xFE\x00".b,
      'an attached mail, as the walk passes it' =>
        Mail::Body.new("Subject: inner\n\ninner body\n"),
      'a fixture' => File.binread(
        Rails.root.join('spec/fixtures/files/incoming-request-plain.eml')
      )
    }

    sources.each do |name, source|
      it "makes of #{name} what Rails's Mail.from_source makes" do
        ours = mail_from_source(source)
        rails = Mail.from_source(source)
        expect(ours.raw_source).to eq(rails.raw_source)
        expect(ours.raw_source.encoding).to eq(rails.raw_source.encoding)
        expect(ours.class).to eq(rails.class)
      end
    end
  end

  describe 'a name or header value that is nothing but whitespace' do
    def parts_of(source)
      get_attachment_attributes(Mail.from_source(source.gsub("\n", "\r\n")))
    end

    def mail_with_part_named(name)
      <<~MAIL
        From: a@example.com
        Subject: outer
        MIME-Version: 1.0
        Content-Type: multipart/mixed; boundary="b"

        --b
        Content-Type: text/plain

        hello
        --b
        Content-Type: application/x-zip-compressed; name="#{name}"
        Content-Transfer-Encoding: base64

        UEsDBA==
        --b--
      MAIL
    end

    def mail_with_attached_subject(subject)
      <<~MAIL
        From: a@example.com
        Subject: outer
        MIME-Version: 1.0
        Content-Type: multipart/mixed; boundary="b"

        --b
        Content-Type: text/plain

        hello
        --b
        Content-Type: message/rfc822

        From: c@example.com
        Subject: #{subject}
        Content-Type: text/plain

        inner
        --b--
      MAIL
    end

    it 'keeps a part\'s name when its content type is normalised' do
      part = parts_of(mail_with_part_named('report.zip')).last
      expect(part).to include(filename: 'report.zip',
                              content_type: 'application/zip')
    end

    it 'gives a part named with a no-break space no name' do
      part = parts_of(mail_with_part_named("\u00a0")).last
      expect(part).to include(filename: nil, content_type: 'application/zip')
    end

    it 'puts an attached mail\'s subject above its text' do
      part = parts_of(mail_with_attached_subject('real')).last
      expect(part[:body]).
        to eq("Subject: real\nFrom: c@example.com\n\ninner")
    end

    it 'leaves out an attached mail\'s subject of one ideographic space' do
      part = parts_of(mail_with_attached_subject("\u3000")).last
      expect(part[:body]).to eq("From: c@example.com\n\ninner")
    end
  end
end
