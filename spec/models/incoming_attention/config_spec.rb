require 'spec_helper'

RSpec.describe IncomingAttention::Config do
  it 'uses one explicit switch and no deployment fingerprint' do
    allow(AlaveteliConfiguration).
      to receive(:incoming_attention_enabled).and_return(false)
    expect(described_class.enabled?).to be false
    expect(described_class.contract).
      to eq('contract_version' => 'incoming-attention/v5')
    expect(described_class).not_to respond_to(:fingerprint)
  end

  it 'is on only when general.yml says true' do
    [false, nil, '', 'true', 'on', 1].each do |value|
      allow(AlaveteliConfiguration).
        to receive(:incoming_attention_enabled).and_return(value)
      expect(described_class.enabled?).to be false
    end
    allow(AlaveteliConfiguration).
      to receive(:incoming_attention_enabled).and_return(true)
    expect(described_class.enabled?).to be true
  end

  it 'defaults historical backfill off and accepts only an explicit zoned timestamp' do
    [nil,
     '',
     true,
     123,
     'true',
     'yesterday',
     '2026-10-06T12:00:00',
     '2026-99-99T12:00:00Z'].each do |value|
      allow(AlaveteliConfiguration).
        to receive(:incoming_attention_backfill_received_after).and_return(
          value
        )
      expect(described_class.backfill_received_after).to be_nil
    end
    allow(AlaveteliConfiguration).
      to receive(:incoming_attention_backfill_received_after).
      and_return('2026-10-06T13:00:00+01:00')
    expect(described_class.backfill_received_after).
      to eq(Time.utc(2026, 10, 6, 12))
  end

  it 'takes the token from the environment, never from general.yml' do
    allow(ENV).to receive(:[]).and_call_original
    allow(ENV).
      to receive(:[]).with('INCOMING_ATTENTION_AUTH_TOKEN').and_return(
        'from-the-environment'
      )
    expect(described_class.token).to eq('from-the-environment')
    expect(AlaveteliConfiguration::DEFAULTS.keys.grep(/TOKEN/)).to be_empty
  end
end
