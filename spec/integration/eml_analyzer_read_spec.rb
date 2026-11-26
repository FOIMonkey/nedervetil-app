require 'spec_helper'

RSpec.describe ExcelAnalyzer::EmlAnalyzer, 'reading the email' do
  include MailReadHelpers

  let(:path) do
    Rails.root.join('spec/fixtures/files/incoming-request-two-same-name.eml')
  end
  let(:blob) do
    blob = double(content_type: 'message/rfc822', service_name: 'raw_emails')
    allow(blob).to receive(:open).and_yield(File.open(path))
    blob
  end

  it 'asks what the email holds, and for no part’s bytes' do
    reads = watch_mail_reads

    expect(described_class.new(blob).metadata).to eq({})
    expect(reads.map { |read| read[:options] }).to eq([{ bodies: false }])
  end

  # The analysis only brings the reply's parse forward. The arrival job
  # parses the reply either way, and the spreadsheet check follows the parse.
  it 'brings no parse forward when the email can’t be read, and is not ' \
     'tried again' do
    refuse_mail_reads
    expect(ExcelAnalyzer.on_spreadsheet_received).not_to receive(:call)

    expect(described_class.new(blob).metadata).to eq({})
  end

  it 'brings no parse forward for an email past the part limits' do
    allow(MailHandler::Reading).to receive(:of).
      and_raise(MailHandler::TooComplex, 'mail part limit exceeded')
    expect(ExcelAnalyzer.on_spreadsheet_received).not_to receive(:call)

    expect(described_class.new(blob).metadata).to eq({})
  end
end
