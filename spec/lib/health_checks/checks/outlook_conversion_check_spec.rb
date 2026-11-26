require 'spec_helper'

RSpec.describe HealthChecks::Checks::OutlookConversionCheck do
  let(:check) do
    described_class.new(failure_message: 'Outlook can’t be converted',
                        success_message: 'Outlook can be converted')
  end

  it 'passes when msgconvert converts the built-in message' do
    expect(check).to be_ok
    expect(check.message).to eq('Outlook can be converted: msgconvert ran')
  end

  it 'says msgconvert ran in the mail cell, with converter cells' do
    allow(MailHandler).to receive(:outlook_self_test)
    allow(AlaveteliSandbox::Cell).to receive(:configured?).and_return(true)
    expect(check.message).
      to eq('Outlook can be converted: msgconvert ran in the mail cell')
  end

  it 'fails, saying why, when msgconvert can’t run' do
    allow(AlaveteliSandbox).to receive(:job).and_raise(
      AlaveteliSandbox::Failed.new('msgconvert is not installed')
    )
    expect(check).not_to be_ok
    expect(check.message).to eq(
      'Outlook can’t be converted: MailHandler::ReadRefused: msgconvert ' \
      'could not run: msgconvert is not installed'
    )
  end

  it 'fails when msgconvert runs and gives something else' do
    allow(MailHandler).to receive(:outlook_as_mime).
      and_return("Subject: Something else\r\n\r\n")
    expect(check).not_to be_ok
    expect(check.message).to include('did not convert the built-in message')
  end

  it 'fails when msgconvert cannot convert the built-in message' do
    allow(MailHandler).to receive(:outlook_as_mime).and_return(nil)
    expect(check).not_to be_ok
  end

  it 'converts at most once a minute' do
    allow(MailHandler).to receive(:outlook_self_test)
    2.times { check.ok? && check.message }
    travel(2.minutes) { check.ok? }
    expect(MailHandler).to have_received(:outlook_self_test).twice
  end
end
