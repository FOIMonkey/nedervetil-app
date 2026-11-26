require 'spec_helper'

RSpec.describe 'Outgoing message delivery status page', type: :request do
  let(:lines) do
    <<~EOF.split("\n")
      2015-09-22 17:36:56 [2035] 1ZeQYq-0000Wm-1V => body@example.com F=<request@example.com> P=<request@example.com> R=dnslookup T=remote_smtp S=1685 H=mail.example.com [62.208.144.158]:25 C="250 2.0.0 Ok: queued as 95FC94583B8" QT=0s DT=0s\n
      2015-09-22 17:36:56 [2032] 1ZeQYq-0000Wm-1V <= request@example.com U=alaveteli P=local S=1645 id=ogm-12iu1h22@example.com T="An FOI Request about Potatoes" from <request@example.com> for body@example.com body@example.com\n
      2015-11-22 00:37:01 [17622] 1a0IeK-0004aB-Na => body@example.com <body@example.com> F=<request@example.com> P=<request@example.com> R=dnslookup T=remote_smtp S=4137 H=prefilter.emailsecurity.trendmicro.eu [150.70.226.147]:25 X=TLS1.2:DHE_RSA_AES_128_CBC_SHA1:128 CV=no DN="C=US,ST=California,L=Cupertino,O=Trend Micro Inc.,CN=*.emailsecurity.trendmicro.eu" C="250 2.0.0 Ok: queued as 8878A680030" QT=1s DT=0s\n
      2015-11-22 00:37:00 [17619] 1a0IeK-0004aB-Na <= request@example.com U=alaveteli P=local S=3973 id=ogm-jh217mwec@example.com@localhost T="RE: An FOI Request about Potatoes 15" from <request@example.com> for body@example.com body@example.com\n
    EOF
  end

  let(:logs) { lines.map { |line| MailServerLog.new(line: line) } }

  let(:status) { MailServerLog::DeliveryStatus.new(:delivered) }

  let(:page) { Nokogiri::HTML(response.body) }

  # A refusal must come from the rules, not from a sign-in that failed.
  def expect_signed_in
    get edit_users_name_path
    expect(response).to have_http_status(:ok)
  end

  describe 'GET show' do
    let(:user) { FactoryBot.create(:user) }
    let(:info_request) { FactoryBot.build(:info_request) }

    let(:message) do
      FactoryBot.create(
        :initial_request, info_request: info_request, prominence: 'normal'
      )
    end

    let(:status_path) { outgoing_message_delivery_status_path(message) }

    before do
      sign_in user
      allow(OutgoingMessage).to receive(:find).and_call_original
      allow(OutgoingMessage).to receive(:find).with(message.id.to_s).
        and_return(message)
      allow(message).to receive(:mail_server_logs).and_return(logs)
      allow(message).to receive(:delivery_status).and_return(status)
    end

    shared_examples 'authenticated' do
      it 'shows the page for the outgoing message, with its title' do
        get status_path
        expect(response).to have_http_status(:ok)
        expect(page.at_css('.page-band__title').text).
          to eq("Delivery Status for Outgoing Message ##{message.id}")
      end

      it 'shows the delivery status of the message' do
        get status_path
        expect(page.at_css('h2').text).to eq(status.humanize)
        expect(response.body).
          to include("We've received a delivery status notification")
      end
    end

    context 'as request owner' do
      let(:user) { FactoryBot.create(:user) }
      let(:info_request) { FactoryBot.build(:info_request, user: user) }

      include_examples 'authenticated'

      it 'shows the mail server logs' do
        get status_path
        expect(response.body).
          to include('These logs show what happened to this message')
      end

      it 'shows the redacted mail server log lines' do
        logs.zip(lines).each do |log, line|
          expect(log).to receive(:line).with(redact: true).and_return(line)
        end

        get status_path
        expect(page.at_css('pre').text).to eq(lines.join)
      end
    end

    context 'as an admin' do
      let(:user) { FactoryBot.create(:admin_user) }
      let(:info_request) { FactoryBot.build(:info_request, user: user) }

      include_examples 'authenticated'

      it 'shows the mail server logs' do
        get status_path
        expect(response.body).
          to include('These logs show what happened to this message')
      end

      it 'shows the unredacted mail server log lines' do
        logs.zip(lines).each do |log, line|
          expect(log).to receive(:line).with(redact: false).and_return(line)
        end

        get status_path
        expect(page.at_css('pre').text).to eq(lines.join)
      end
    end

    context 'as other user' do
      it 'answers not found, as for a message that does not exist' do
        expect_signed_in
        get status_path
        expect(response).to have_http_status(:not_found)
        expect(page.css('.page-band__title, h2').map(&:text)).
          not_to include(/Delivery Status/, status.humanize)
        expect(response.body).not_to include('1ZeQYq-0000Wm-1V')
      end
    end

    context 'when the requester cannot view the message' do
      let(:info_request) { FactoryBot.build(:info_request, user: user) }
      let(:message) do
        FactoryBot.create(
          :initial_request, info_request: info_request, prominence: 'hidden'
        )
      end

      it 'renders hidden' do
        expect_signed_in
        get status_path
        expect(response).to have_http_status(:forbidden)
        expect(page.at_css('#hidden_message')).to be_present
        expect(page.css('.page-band__title, h2').map(&:text)).
          not_to include(/Delivery Status/, status.humanize)
        expect(response.body).not_to include('1ZeQYq-0000Wm-1V')
      end
    end

    context 'when the request cannot be viewed' do
      let(:info_request) do
        FactoryBot.build(:info_request, user: user, prominence: 'hidden')
      end

      it 'answers not found' do
        expect_signed_in
        get status_path
        expect(response).to have_http_status(:not_found)
      end
    end
  end
end
