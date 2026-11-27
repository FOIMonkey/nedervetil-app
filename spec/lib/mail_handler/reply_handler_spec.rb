require 'spec_helper'
require 'mail_handler/reply_handler'

RSpec.describe MailHandler::ReplyHandler do
  describe '.forward_on' do
    describe 'non-bounce mails' do
      let(:mail) { get_fixture_mail('normal-contact-reply.eml') }

      it 'forwards the mail to sendmail' do
        expect(IO).
          to receive(:popen).
          with(['/usr/sbin/sendmail', '-i', '--', 'user-support@localhost'],
               'wb')
        MailHandler::ReplyHandler.forward_on(mail.raw_source, mail)
      end
    end
  end

  # Every reply that isn't a bounce goes to the one support address, even
  # one sent to the Pro contact's old address.
  describe '.get_forward_to_address' do
    let(:normal_recipient) do
      AlaveteliConfiguration.forward_nonbounce_responses_to
    end

    it 'returns the support address for a reply to the contact address' do
      mail = get_fixture_mail('normal-contact-reply.eml')
      expect(MailHandler::ReplyHandler.get_forward_to_address(mail)).
        to eq(normal_recipient)
    end

    it 'returns the support address for a reply to the old Pro contact' do
      mail = get_fixture_mail('pro-contact-reply.eml')
      expect(MailHandler::ReplyHandler.get_forward_to_address(mail)).
        to eq(normal_recipient)
    end
  end

  describe '.permanently_failed_addresses and .is_oof?' do
    it 'ignores spoofed bounce subjects without empty return-path or Auto-Submitted' do
      mail = Mail.new do
        from 'attacker@example.org'
        to 'contact@localhost'
        subject 'Returned Mail: Error During Delivery'
        body "---- Failed Recipients ----\n<victim@example.org>\n"
      end
      mail.return_path = 'attacker@example.org'

      expect(described_class.permanently_failed_addresses(mail)).to eq([])
    end

    it 'handles messages with no Subject header in .is_oof?' do
      mail = Mail.new { from 'sender@example.org' }
      expect(described_class.is_oof?(mail)).to be(false)
    end
  end
end
