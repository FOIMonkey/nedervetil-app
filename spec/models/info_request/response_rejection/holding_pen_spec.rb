require 'spec_helper'

RSpec.describe InfoRequest::ResponseRejection::HoldingPen do
  it 'inherits from Base' do
    expect(described_class.superclass).
      to eq(InfoRequest::ResponseRejection::Base)
  end

  describe '.new' do
    it 'finds and sets the holding_pen' do
      rejection = described_class.new(double, double)
      expect(rejection.holding_pen).to be_holding_pen_request
    end
  end

  describe '.reject' do
    it 'returns false if the info_request is the holding_pen' do
      holding_pen = InfoRequest.holding_pen_request
      rejection = described_class.new(holding_pen, double)
      expect(rejection.reject).to eq(false)
    end

    it 'redirects the mail to the holding pen' do
      info_request = FactoryBot.create(:info_request)
      inbound_email = <<-EOF.strip_heredoc
      From: sender@example.com
      To: FOI Person <authority@example.com>
      Subject: External
      Hello, World
      EOF
      mail = Mail.from_source(inbound_email)
      args = [info_request, mail]

      described_class.new(*args).reject

      expect(InfoRequest.holding_pen_request.incoming_messages.count).to eq(1)
    end

    it 'says the mail was rejected, the first time and when the holding ' \
       'pen has it already' do
      info_request = FactoryBot.create(:info_request)
      mail = Mail.from_source(<<~EML)
        From: sender@example.com
        Message-ID: <twice@example.com>
        Subject: External

        Hello, World
      EML

      results = Array.new(2) { described_class.new(info_request, mail).reject }

      expect(results).to eq([true, true])
      expect(InfoRequest.holding_pen_request.incoming_messages.count).to eq(1)
    end

    it 'stores the inbound email\'s ids with the holding pen\'s copy' do
      info_request = FactoryBot.create(:info_request)
      mail = Mail.from_source("From: sender@example.com\n\nHello\n")

      described_class.new(info_request, mail, message_id: 'abc@host.mail',
                                              message_checksum: 'abc').reject

      raw_email = InfoRequest.holding_pen_request.incoming_messages.last.
                    raw_email
      expect(raw_email[:message_id]).to eq('abc@host.mail')
      expect(raw_email[:message_checksum]).to eq('abc')
    end
  end
end
