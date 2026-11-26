require 'spec_helper'

RSpec.describe HealthChecks::Checks::MailReadCheck do
  let(:check) do
    described_class.new(failure_message: 'Mail can’t be read',
                        success_message: 'Mail can be read')
  end

  it 'passes when the built-in mail is read, its Outlook message unpacked' do
    expect(check).to be_ok
    expect(check.message).
      to eq('Mail can be read: read a tiny mail in this process')
  end

  it 'says where the mail was read' do
    allow(MailHandler::Reading).to receive(:self_test)
    allow(AlaveteliConfiguration).
      to receive(:sandbox_converters).and_return('required')
    expect(check.message).to end_with('in the sandbox')

    allow(AlaveteliSandbox::Cell).to receive(:configured?).and_return(true)
    expect(described_class.new(success_message: 'Read').message).
      to end_with('in the mail cell')
  end

  it 'fails, saying why, when the read is refused' do
    allow(MailHandler::Reading).to receive(:of).
      and_raise(MailHandler::ReadRefused, 'the mail cell is down')
    expect(check).not_to be_ok
    expect(check.message).to eq(
      'Mail can’t be read: MailHandler::ReadRefused: the mail cell is down'
    )
  end

  it 'fails when the attached Outlook message was not unpacked' do
    allow(MailHandler).to receive(:outlook_as_mime).and_return(nil)
    expect(check).not_to be_ok
    expect(check.message).to include('not read as expected')
  end

  it 'reads at most once a minute' do
    allow(MailHandler::Reading).to receive(:self_test)
    2.times { check.ok? && check.message }
    travel(2.minutes) { check.ok? }
    expect(MailHandler::Reading).to have_received(:self_test).twice
  end
end
