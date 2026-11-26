require 'spec_helper'

RSpec.describe AlaveteliConfiguration do
  include AlaveteliConfiguration

  describe '#to_sanitized_hash' do
    subject { described_class.to_sanitized_hash }
    it { is_expected.to include(INCOMING_EMAIL_SECRET: '[FILTERED]') }

    it 'filters keys, tokens, passwords and licence keys' do
      %w[WORKER_TOKEN DATABASE_PASSWORD LICENSE_KEY SIGNING_KEY].each do |key|
        expect(key).to match(described_class.sensitive_key_patterns)
      end
      expect(subject).to include(SECRET_KEY_BASE: '[FILTERED]')
    end
  end
end
