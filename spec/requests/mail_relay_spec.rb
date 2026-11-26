require 'spec_helper'

RSpec.describe 'Mail posted by the relay', type: :request do
  let(:password) { 'a-relay-password-of-twenty-or-more' }
  let(:info_request) { FactoryBot.create(:info_request) }

  before do
    allow(Rails.application.credentials).to receive(:dig).and_call_original
    allow(Rails.application.credentials).to receive(:dig).
      with(:action_mailbox, :ingress_password).and_return(password)
  end

  # Routed by envelope headers; the message's own To is Undisclosed recipients.
  def relayed(body, to: info_request.incoming_email)
    "X-Alaveteli-Ingress: cloudflare-relay-v1\r\n" \
      "X-Alaveteli-Envelope-To: #{to}\r\n" \
      "Envelope-To: #{to}\r\n" \
      "Return-Path: <officer@authority.example>\r\n" \
      "From: FOI Officer <officer@authority.example>\r\n" \
      "To: Undisclosed recipients:;\r\n" \
      "Subject: Re: Your request\r\n" \
      "Message-ID: <reply-1@authority.example>\r\n" \
      "Date: Tue, 17 Nov 2026 11:00:00 +0000\r\n" \
      "MIME-Version: 1.0\r\n".b + body
  end

  # Latin-1 sent as it is, so the body is not valid UTF-8.
  let(:latin1_reply) do
    relayed("Content-Type: text/plain; charset=iso-8859-1\r\n" \
            "Content-Transfer-Encoding: 8bit\r\n\r\n".b +
            "The caf\xE9 holds the records.\r\n".b)
  end

  def post_to_relay(message, type: 'message/rfc822', password: self.password)
    headers = { 'Content-Type' => type }
    if password
      headers['Authorization'] = ActionController::HttpAuthentication::Basic.
        encode_credentials('actionmailbox', password)
    end
    post '/rails/action_mailbox/relay/inbound_emails',
         params: message, headers: headers
  end

  def stored
    ActionMailbox::InboundEmail.
      where(message_id: 'reply-1@authority.example').
      map { |mail| mail.raw_email.download }
  end

  it 'is stored byte for byte and filed on the request the envelope names' do
    post_to_relay(latin1_reply)

    expect(response).to have_http_status(:no_content)
    expect(response.body).to be_empty
    expect(stored).to eq([latin1_reply])

    perform_enqueued_jobs
    reply = info_request.reload.incoming_messages.sole
    expect(reply.raw_email.data.b).to eq(latin1_reply)
    expect(reply.get_main_body_text_folded).
      to eq("The café holds the records.\n")
  end

  it 'is stored byte for byte when it carries megabytes of attachment' do
    file = [Random.new(1).bytes(2_000_000)].pack('m').gsub("\n", "\r\n")
    message = relayed(
      "Content-Type: application/octet-stream; name=records.bin\r\n" \
      "Content-Transfer-Encoding: base64\r\n" \
      "Content-Disposition: attachment; filename=records.bin\r\n\r\n".b +
      file.b
    )

    post_to_relay(message)

    expect(response).to have_http_status(:no_content)
    expect(stored.map(&:bytesize)).to eq([message.bytesize])
    expect(stored.first == message).to be(true)
  end

  it 'answers with no body, no cookie and nothing to cache' do
    post_to_relay(latin1_reply)

    expect(sent_headers.except('content-security-policy')).to eq(
      'cache-control' => 'no-cache',
      'referrer-policy' => 'strict-origin-when-cross-origin',
      'x-content-type-options' => 'nosniff',
      'x-frame-options' => 'sameorigin',
      'x-permitted-cross-domain-policies' => 'none'
    )
  end

  it 'is refused, and nothing stored, with the wrong password or none' do
    [password.reverse, nil].each do |given|
      expect { post_to_relay(latin1_reply, password: given) }.
        not_to change(ActionMailbox::InboundEmail, :count)

      expect(response).to have_http_status(:unauthorized)
      expect(response.headers['www-authenticate']).
        to eq('Basic realm="Action Mailbox"')
    end
  end

  it 'is refused, and nothing stored, unless it is sent as a message' do
    expect { post_to_relay(latin1_reply, type: 'text/plain') }.
      not_to change(ActionMailbox::InboundEmail, :count)

    expect(response).to have_http_status(:unsupported_media_type)
  end
end
