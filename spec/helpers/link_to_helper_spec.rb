require 'spec_helper'

RSpec.describe LinkToHelper do
  include LinkToHelper

  describe 'when creating a url for a request' do
    let(:info_request) { FactoryBot.create(:info_request) }

    it 'should return a path like /request/test_title' do
      expected = "/request/#{info_request.url_title}"
      expect(request_path(info_request)).to eq(expected)
    end

    it 'should return a path including any extra parameters passed' do
      expected = "/request/#{info_request.url_title}?update_status=1"
      actual = request_path(info_request, { update_status: 1 })
      expect(actual).to eq(expected)
    end
  end

  describe 'when linking to new incoming messages' do
    let(:incoming_message) { FactoryBot.create(:incoming_message) }
    let(:info_request) { incoming_message.info_request }

    context 'for external links' do
      subject(:url) { incoming_message_url(incoming_message) }

      it 'generates the url to the info request of the message' do
        expect(url).
          to include("http://test.host/request/#{info_request.url_title}")
      end

      it 'includes an anchor to the new message' do
        expect(url).to include("#incoming-#{incoming_message.id}")
      end

      it 'does not cache by default' do
        expect(url).not_to include("nocache=incoming-#{incoming_message.id}")
      end

      it 'includes a cache busting parameter if set' do
        url = incoming_message_url(incoming_message, cachebust: true)
        expect(url).to include("nocache=incoming-#{incoming_message.id}")
      end
    end

    context 'for internal links' do
      subject(:path) { incoming_message_path(incoming_message) }

      it 'generates the incoming_message_url with the path only' do
        expected = "/request/#{info_request.url_title}" \
                   "#incoming-#{incoming_message.id}"
        expect(path).to eq(expected)
      end
    end

    context 'when anchor only' do
      subject(:url) do
        incoming_message_url(incoming_message, anchor_only: true)
      end

      it 'returns an anchor to the new message' do
        expect(url).to eq("#incoming-#{incoming_message.id}")
      end
    end
  end

  # Every request is private to its requester, so every link goes through
  # sign-in, whatever the requester's role.
  describe 'when linking to new responses' do
    let(:incoming_message) { FactoryBot.create(:incoming_message) }
    let(:info_request) { incoming_message.info_request }

    def expected_url
      signin_url(r: incoming_message_url(incoming_message, cachebust: true))
    end

    it 'creates a sign in url to the cachebusted incoming message url' do
      expect(new_response_url(info_request, incoming_message)).
        to eq(expected_url)
    end

    it 'does the same for a requester without the Pro role' do
      expect(new_response_url(info_request, incoming_message)).
        to eq(expected_url)
    end
  end

  describe 'when linking to new outgoing messages' do
    let(:outgoing_message) { FactoryBot.create(:new_information_followup) }
    let(:info_request) { outgoing_message.info_request }

    subject(:url) { outgoing_message_url(outgoing_message) }

    context 'for external links' do
      it 'generates the url to the info request of the message' do
        expect(url).
          to include("http://test.host/request/#{info_request.url_title}")
      end

      it 'includes an anchor to the new message' do
        expect(url).to include("#outgoing-#{outgoing_message.id}")
      end

      it 'does not cache by default' do
        expect(url).not_to include("nocache=outgoing-#{outgoing_message.id}")
      end

      it 'includes a cache busting parameter if set' do
        url = outgoing_message_url(outgoing_message, cachebust: true)
        expect(url).to include("nocache=outgoing-#{outgoing_message.id}")
      end
    end

    context 'for internal links' do
      it 'generates the outgoing_message_url with the path only' do
        expected = "/request/#{info_request.url_title}" \
                   "#outgoing-#{outgoing_message.id}"
        expect(outgoing_message_path(outgoing_message)).to eq(expected)
      end
    end

    context 'when anchor only' do
      subject(:url) do
        outgoing_message_url(outgoing_message, anchor_only: true)
      end

      it 'returns an anchor to the new message' do
        expect(url).to eq("#outgoing-#{outgoing_message.id}")
      end
    end
  end

  describe 'when linking to attachments' do
    let(:info_request) do
      FactoryBot.create(:info_request, :with_plain_incoming)
    end
    let(:incoming_message) { info_request.incoming_messages.first }
    let(:attachment) { incoming_message.foi_attachments.first }

    context 'for external links' do
      subject { foi_attachment_url(attachment) }

      it 'generates the url to the info request of the message' do
        is_expected.to include \
          "http://test.host/request/#{info_request.url_title}"
      end

      it 'includes an anchor to the attachment' do
        is_expected.to include("#attachment-#{attachment.id}")
      end
    end

    context 'for internal links' do
      subject { foi_attachment_path(attachment) }

      it 'generates the outgoing_message_url with the path only' do
        is_expected.to eq \
          "/request/#{info_request.url_title}#attachment-#{attachment.id}"
      end
    end
  end

  describe 'when displaying a user link for a request' do
    context "for normal requests" do
      let(:info_request) { FactoryBot.create(:info_request) }
      let(:user) { info_request.user }

      it 'should display a relative link by default' do
        expected = "<a href=\"/user/#{user.url_name}\">#{user.name}</a>"
        expect(request_user_link(info_request)).to eq(expected)
      end

      it 'should display an absolute link if requested' do
        expected = "<a href=\"http://test.host/user/#{user.url_name}\">" \
                   "#{user.name}</a>"
        expect(request_user_link_absolute(info_request)).to eq(expected)
      end
    end
  end

  describe '#current_path_without_locale' do
    before do
      AlaveteliLocalization.set_locales('en cy', 'en')
      allow(controller.request).to receive(:path_info).
        and_return('/body/welsh_government')
      allow(controller.request).to receive(:query_parameters).
        and_return('locale' => 'cy')
    end

    it 'removes locale from current path' do
      allow(controller).to receive(:params).and_return(
        ActionController::Parameters.new(
          controller: 'public_body', action: 'show',
          url_name: 'welsh_government', view: 'all',
          locale: 'cy'
        )
      )
      expect(current_path_without_locale).
        to eq '/body/welsh_government'
    end

    it 'ignores current protocol and host' do
      allow(controller).to receive(:params).and_return(
        ActionController::Parameters.new(
          controller: 'public_body', action: 'show',
          url_name: 'welsh_government', view: 'all',
          protocol: 'http', host: 'example.com',
          locale: 'cy'
        )
      )
      expect(current_path_without_locale).
        to eq '/body/welsh_government'
    end

    it 'does not copy submitted credentials into a redirect URL' do
      allow(controller.request).to receive(:request_parameters).
        and_return('password' => 'demo-password', 'otp_code' => '424242')
      allow(controller).to receive(:params).and_return(
        ActionController::Parameters.new(
          controller: 'public_body', action: 'show',
          url_name: 'welsh_government', view: 'all', locale: 'cy',
          password: 'demo-password', otp_code: '424242'
        )
      )
      expect(current_path_without_locale).
        to eq '/body/welsh_government'
    end

    it 'keeps ordinary query parameters without accepting URL options' do
      allow(controller.request).to receive(:query_parameters).
        and_return('locale' => 'cy', 'q' => 'water', 'host' => 'evil.example')
      expect(current_path_without_locale).
        to eq '/body/welsh_government?host=evil.example&q=water'
    end
  end

  describe '#current_path_with_locale' do
    before do
      AlaveteliLocalization.set_locales('en cy', 'en')
      allow(controller.request).to receive(:path_info).
        and_return('/body/welsh_government')
      allow(controller.request).to receive(:query_parameters).
        and_return({})
    end

    it 'adds locale parameter to current path' do
      allow(controller).to receive(:params).and_return(
        ActionController::Parameters.new(
          controller: 'public_body', action: 'show',
          url_name: 'welsh_government', view: 'all'
        )
      )
      expect(current_path_with_locale('cy')).
        to eq '/body/welsh_government?locale=cy'
    end

    it 'ignores current protocol and host' do
      allow(controller).to receive(:params).and_return(
        ActionController::Parameters.new(
          controller: 'public_body', action: 'show',
          url_name: 'welsh_government', view: 'all',
          protocol: 'http', host: 'example.com'
        )
      )
      expect(current_path_with_locale('cy')).
        to eq '/body/welsh_government?locale=cy'
    end

    it 'does not copy submitted credentials into a language link' do
      allow(controller.request).to receive(:request_parameters).
        and_return('password' => 'demo-password', 'otp_code' => '424242')
      allow(controller).to receive(:params).and_return(
        ActionController::Parameters.new(
          controller: 'public_body', action: 'show',
          url_name: 'welsh_government', view: 'all',
          password: 'demo-password', otp_code: '424242'
        )
      )
      expect(current_path_with_locale('cy')).
        to eq '/body/welsh_government?locale=cy'
    end

    it 'uses the request path even if the proxy prefix looks like a URL' do
      allow(controller.request).to receive(:script_name).
        and_return('//evil.example')
      expect(current_path_with_locale('cy')).
        to eq '/body/welsh_government?locale=cy'
    end

    it 'keeps a path with extra leading slashes on this site' do
      allow(controller.request).to receive(:path_info).
        and_return('//evil.example/path')
      expect(current_path_with_locale('cy')).
        to eq '/evil.example/path?locale=cy'
    end
  end

  describe '#incoming_message_dom_id' do
    subject { incoming_message_dom_id(incoming_message) }
    let(:incoming_message) { FactoryBot.create(:incoming_message) }

    context 'incoming message with main body part' do
      it 'returns main body part attachment dom ID' do
        main_body_part = incoming_message.get_main_body_text_part
        is_expected.to eq "attachment-#{main_body_part.to_param}"
      end
    end

    context 'incoming message without main body part' do
      before { allow(incoming_message).to receive(:get_main_body_text_part) }
      it { is_expected.to be_nil }
    end
  end
end
