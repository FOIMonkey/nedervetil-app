require 'spec_helper'

RSpec.describe MailHandler::Headers do
  include MailHandler

  describe :get_subject do
    it 'returns nil for a nil subject' do
      mail = Mail.new
      expect(get_subject(mail)).to be nil
    end

    it 'returns valid UTF-8 for a non UTF-8 subject' do
      mail = Mail.new
      allow(mail).to receive(:subject).and_return("FOI ACT \x96 REQUEST")
      expect(get_subject(mail).force_encoding('UTF-8').valid_encoding?).
        to be true
    end
  end

  describe :first_from do
    it 'finds the first from field' do
      mail = get_fixture_mail('raw_email_1.eml')
      expected = Mail::Address.new('FOI Person <foiperson@localhost>').to_s
      expect(first_from(mail).to_s).to eq(expected)
    end
  end

  describe :get_from_address do
    it 'finds the first address' do
      mail = get_fixture_mail('raw_email_1.eml')
      expect(get_from_address(mail)).to eq('foiperson@localhost')
    end
  end

  describe :get_from_name do
    it 'finds the first from name' do
      mail = get_fixture_mail('raw_email_1.eml')
      expect(get_from_name(mail)).to eq('FOI Person')
    end
  end

  describe '.get_all_addresses' do
    let(:valid_only) do
      Mail.new(<<-EOF.strip_heredoc)
      From: "FOI Person" <foiperson@localhost>
      To: "Bob Smith" <bob@localhost>
      Cc: bob@example.com
      Envelope-To: bob@example.net
      Date: Tue, 13 Nov 2007 11:39:55 +0000
      Bcc: "BCC Person" <bccperson@localhost>
      Subject: Test
      Reply-To:

      Test
      EOF
    end

    let(:with_invalid) do
      Mail.new(<<-EOF.strip_heredoc)
      From: "FOI Person" <foiperson@localhost>
      To: <Bob Smith <bob@localhost>
      Cc: bob@example.com>
      Envelope-To: bob@example.net
      Date: Tue, 13 Nov 2007 11:39:55 +0000
      Bcc: BCC Person bccperson@localhost>
      Subject: Test
      Reply-To:

      Test
      EOF
    end

    context 'include_invalid: false' do
      subject { MailHandler.get_all_addresses(mail) }

      context 'with a mail with only valid addresses' do
        let(:mail) { valid_only }

        it do
          is_expected.to eq(%w(
                              bob@localhost
                              bob@example.com
                              bccperson@localhost
                              bob@example.net
                            ))
        end
      end

      context 'with an email with invalid addresses' do
        let(:mail) { with_invalid }
        it { is_expected.to eq(%w(bob@example.net)) }
      end
    end

    context 'include_invalid: true' do
      subject { MailHandler.get_all_addresses(mail, include_invalid: true) }

      context 'with a mail with only valid addresses' do
        let(:mail) { valid_only }

        it do
          is_expected.to eq(%w(
                              bob@localhost
                              bob@example.com
                              bccperson@localhost
                              bob@example.net
                            ))
        end
      end

      context 'with an email with invalid addresses' do
        let(:mail) { with_invalid }

        it do
          expected = [
            '<Bob Smith <bob@localhost>',
            'bob@example.com>',
            'BCC Person bccperson@localhost>',
            'bob@example.net'
          ]
          is_expected.to eq(expected)
        end
      end
    end
  end

  describe :empty_return_path? do
    it 'is false if the return path is nil' do
      mail = Mail.new
      expect(empty_return_path?(mail)).to be false
    end

    it 'is false if the return path has some data' do
      mail = Mail.new
      mail['return-path'] = 'xyz'
      expect(empty_return_path?(mail)).to be false
    end

    it 'is true if the return path is blank' do
      mail = Mail.new
      mail['return-path'] = ''
      expect(empty_return_path?(mail)).to be true
    end
  end

  describe :get_auto_submitted do
    it 'returns the auto-submitted attribute' do
      mail = Mail.new
      mail['auto-submitted'] = 'xyz'
      expect(get_auto_submitted(mail)).to eq('xyz')
    end

    it 'returns nil if there is no auto-submitted attribute' do
      mail = Mail.new
      expect(get_auto_submitted(mail)).to be_nil
    end
  end

  describe :address_from_name_and_email do
    it 'returns an address string' do
      expected = 'Test User <test@example.com>'
      expect(address_from_name_and_email('Test User', 'test@example.com')).
        to eq(expected)
    end

    it 'does not change the name passed to it' do
      original = "brønn"
      name = original.dup
      address_from_name_and_email(name, 'test@example.com')
      expect(name).to eq(original)
    end
  end

  describe :get_emails_within_received_headers do
    it 'returns an empty list if there is no Received header' do
      mail = get_fixture_mail('bcc-contact-reply.eml')
      expect(get_emails_within_received_headers(mail)).to eq([])
    end

    it 'returns an empty list if the Received header contains no email addresses' do
      mail = Mail.new(<<~EOF.strip_heredoc)
        From: "FOI Person" <foiperson@localhost>
        To: "Bob Smith" <bob@localhost>
        Cc: bob@example.com
        Envelope-To: bob@example.net
        Received: abc id abc from notAnEmail
        Date: Tue, 13 Nov 2007 11:39:55 +0000
        Bcc: "BCC Person" <bccperson@localhost>
        Subject: Test
        Reply-To:

        Test
      EOF

      expect(get_emails_within_received_headers(mail)).to eq([])
    end

    it 'returns a list containing the email if the Received header contains one email address' do
      mail = Mail.new(<<~EOF.strip_heredoc)
        From: "FOI Person" <foiperson@localhost>
        To: "Bob Smith" <bob@localhost>
        Cc: bob@example.com
        Envelope-To: bob@example.net
        Received: abc id abc from aperson@domain.abc
        Date: Tue, 13 Nov 2007 11:39:55 +0000
        Bcc: "BCC Person" <bccperson@localhost>
        Subject: Test
        Reply-To:

        Test
      EOF

      expect(get_emails_within_received_headers(mail)).
        to eq(['aperson@domain.abc'])
    end

    it 'returns a (single dimensional) list containing the emails if the Received header contains multiple email addresses' do
      mail = Mail.new(<<~EOF.strip_heredoc)
        From: "FOI Person" <foiperson@localhost>
        To: "Bob Smith" <bob@localhost>
        Cc: bob@example.com
        Envelope-To: bob@example.net
        Received: abc id abc from aperson@domain.abc
          also there is anotherperson@domain.abc
        Date: Tue, 13 Nov 2007 11:39:55 +0000
        Bcc: "BCC Person" <bccperson@localhost>
        Subject: Test
        Reply-To:

        Test
      EOF

      expect(get_emails_within_received_headers(mail)).
        to eq(['aperson@domain.abc', 'anotherperson@domain.abc'])
    end

    it 'recognises the Received header when it is not capitalised' do
      mail = Mail.new(<<~EOF.strip_heredoc)
        From: "FOI Person" <foiperson@localhost>
        To: "Bob Smith" <bob@localhost>
        Cc: bob@example.com
        Envelope-To: bob@example.net
        received: abc id abc from aperson@domain.abc
        Date: Tue, 13 Nov 2007 11:39:55 +0000
        Bcc: "BCC Person" <bccperson@localhost>
        Subject: Test
        Reply-To:

        Test
      EOF

      expect(get_emails_within_received_headers(mail)).
        to eq(['aperson@domain.abc'])
    end
  end
end
