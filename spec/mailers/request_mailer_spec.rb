require 'spec_helper'

RSpec.describe RequestMailer do
  include_context 'with incoming attention off'

  describe "when receiving incoming mail" do
    context 'when passed an UTF-8 encoded mail' do
      let(:inbound_email) do
        # Read fixture file using 'r' mode so we end up with a UTF-8 string
        load_file_fixture('iso8859_1_with_extended_character_set.eml', 'r')
      end

      it 'does not raise error' do
        expect { RequestMailer.receive(inbound_email) }.to_not raise_error
      end

      it 'new mail returns a binary body' do
        mail = RequestMailer.receive(inbound_email).mail
        expect(mail.body.to_s).to eq(
          "Information Governance\xA0Unit\n".force_encoding(Encoding::BINARY)
        )
      end
    end
  end

  describe 'when sending emails' do
    it 'renders the footer partial for a user email' do
      expect_any_instance_of(RequestMailer).to receive(:set_footer_template)
      info_request = FactoryBot.create(:info_request_with_incoming)
      RequestMailer.new_response(info_request,
                                 info_request.incoming_messages.first).message
    end

    it 'does not render the footer partial for a non-user email' do
      expect_any_instance_of(RequestMailer).not_to receive(:set_footer_template)
      info_request = FactoryBot.create(:info_request_with_incoming)
      mail = RequestMailer.
               fake_response(info_request,
                             FactoryBot.build_stubbed(:user),
                             "The body of the email...",
                             "blah.txt",
                             "The content of blah.txt")
      mail.message
    end
  end

  describe "when generating a fake response for an upload" do
    before do
      @foi_officer = FactoryBot.build_stubbed(:user)
      @info_request = instance_double(
        InfoRequest,
        email_subject_followup: 'Re: Freedom of Information - Test request',
        incoming_name_and_email: 'Someone <someone@example.org>'
      )
    end

    it 'should should generate a "fake response" email with a reasonable subject line' do
      fake_email = RequestMailer.fake_response(@info_request,
                                               @foi_officer,
                                               "The body of the email...",
                                               "blah.txt",
                                               "The content of blah.txt")
      expect(fake_email.subject).
        to eq("Re: Freedom of Information - Test request")
    end
  end

  describe "when sending a new response email" do
    let(:user) do
      FactoryBot.create(:user, name: "test name",
                               email: "email@localhost")
    end

    let(:public_body) do
      FactoryBot.create(:public_body, name: "Test public body")
    end

    let(:info_request) do
      FactoryBot.create(:info_request,
                        user: user,
                        title: "Here is a character that needs quoting …",
                        public_body: public_body,
                        described_state: 'rejected',
                        url_title: "test_request")
    end

    let(:incoming_message) do
      FactoryBot.create(:incoming_message, info_request: info_request)
    end

    it 'should not error when sending mails requests with characters requiring quoting in the subject' do
      expect {
        RequestMailer.new_response(info_request, incoming_message).message
      }.not_to raise_error
    end

    it 'should not create HTML entities in the subject line' do
      mail = RequestMailer.new_response(
        FactoryBot.create(:info_request, title: "Here's a request"),
        FactoryBot.create(:incoming_message)
      )
      expect(mail.subject).
        to eq "New response to your FOI request - Here's a request"
    end

    context "when the user does not use default locale" do
      before do
        info_request.title = "A request"
        info_request.user.locale = 'es'
      end

      it "translates the subject" do
        mail = RequestMailer.new_response(
          info_request,
          FactoryBot.create(:incoming_message)
        )
        expect(mail.subject).to eq(
          "Nueva respuesta a tu solicitud de información - A request"
        )
      end
    end

    it 'should send pro users a signin link' do
      pro_user = FactoryBot.create(:pro_user)
      info_request = FactoryBot.create(:info_request, user: pro_user)
      incoming_message = FactoryBot.create(:incoming_message,
                                           info_request: info_request)
      mail = RequestMailer.new_response(info_request, incoming_message)
      mail_url = mail.body.to_s[/(http:\/\/.*)/, 1]

      message_url = incoming_message_url(incoming_message, cachebust: true)
      expected_url = signin_url(r: message_url)
      expect(mail_url).to eq expected_url
    end

    # Every request is private, so every requester gets a sign-in link.
    it 'should send requesters without the Pro role a signin link too' do
      mail = RequestMailer.new_response(info_request, incoming_message)
      mail_url = mail.body.to_s[/(http:\/\/\S*)/, 1]
      message_url = incoming_message_url(incoming_message, cachebust: true)
      expect(mail_url).to eq signin_url(r: message_url)
    end
  end

  describe "requires_admin" do
    let(:user) do
      FactoryBot.create(:user, name: "Bruce Jones",
                               email: "bruce@example.com")
    end

    let(:info_request) do
      FactoryBot.create(:info_request, user: user,
                                       title: "It's a Test request",
                                       url_title: "test_request",
                                       id: 123)
    end

    before do
      info_request.described_state = 'error_message'
      info_request.save!
    end

    it "body should contain the message from the user" do
      mail = RequestMailer.
        requires_admin(info_request, nil, "Something has gone wrong").
          deliver_now
      expect(mail.body).to include 'Something has gone wrong'
    end

    it 'should not create HTML entities in the subject line' do
      expect(RequestMailer.requires_admin(info_request).subject).
        to eq "FOI response requires admin (error_message) - " \
              "It's a Test request"
    end

    it 'sets the "Reply-To" header header to the sender' do
      expect(
        RequestMailer.requires_admin(info_request).header['Reply-To'].to_s
      ).to eq('Bruce Jones <bruce@example.com>')
    end

    it 'sets the "Return-Path" header to the blackhole address' do
      expect(
        RequestMailer.requires_admin(info_request).header['Return-Path'].to_s
      ).to eq('do-not-reply-to-this-address@localhost')
    end

    context "when the user is not a pro" do
      it "sends the request to the normal contact address" do
        expect(RequestMailer.requires_admin(info_request).to).
          to eq([AlaveteliConfiguration.contact_email])
      end
    end

    # One contact address for every account.
    context "when the account used to have the Pro role" do
      let(:pro_user) { FactoryBot.create(:pro_user) }
      let(:pro_request) { FactoryBot.create(:info_request, user: pro_user) }

      it "sends the request to the contact address too" do
        with_feature_enabled(:alaveteli_pro) do
          expect(RequestMailer.requires_admin(pro_request).to).
            to eq([AlaveteliConfiguration.contact_email])
        end
      end
    end
  end
end
