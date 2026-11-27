require 'spec_helper'

RSpec.describe ProductionSafety do
  describe '.check_secret!' do
    it 'refuses the published default' do
      expect do
        described_class.check_secret!(
          AlaveteliConfiguration::DEFAULTS[:SECRET_KEY_BASE]
        )
      end.to raise_error(/SECRET_KEY_BASE/)
    end

    it 'refuses the example placeholder' do
      expect do
        described_class.
          check_secret!('your secret key here, make it long and random')
      end.to raise_error(/SECRET_KEY_BASE/)
    end

    it 'refuses a short secret' do
      expect { described_class.check_secret!('changeme') }.
        to raise_error(/SECRET_KEY_BASE/)
      expect { described_class.check_secret!('a' * 63) }.
        to raise_error(/SECRET_KEY_BASE/)
    end

    it 'accepts 64 characters' do
      expect { described_class.check_secret!('a' * 64) }.not_to raise_error
    end

    it 'accepts a long random secret' do
      expect { described_class.check_secret!(SecureRandom.hex(64)) }.
        not_to raise_error
    end
  end

  describe '.check_admin_auth!' do
    it 'refuses SKIP_ADMIN_AUTH' do
      allow(AlaveteliConfiguration).
        to receive(:skip_admin_auth).and_return(true)
      expect { described_class.check_admin_auth! }.
        to raise_error(/SKIP_ADMIN_AUTH/)
    end

    it 'passes with admin authentication on' do
      allow(AlaveteliConfiguration).
        to receive(:skip_admin_auth).and_return(false)
      expect { described_class.check_admin_auth! }.not_to raise_error
    end
  end

  describe '.check_incoming_email_secret!' do
    it 'refuses defaults, placeholders and short values' do
      ['dummysecret', 'xxxx xxxx xxxx xxxx xxxx xxxx xxxx xxxx',
       'short-secret', nil].each do |bad|
        expect { described_class.check_incoming_email_secret!(bad) }.
          to raise_error(/INCOMING_EMAIL_SECRET/)
      end
    end

    it 'accepts a random 32+ character secret' do
      expect do
        described_class.check_incoming_email_secret!(SecureRandom.hex(24))
      end.not_to raise_error
    end
  end

  describe '.check_encryption_keys!' do
    it 'refuses missing or short keys' do
      bad = Struct.new(:primary_key, :deterministic_key,
                       :key_derivation_salt).new('short', 'a' * 32, 'b' * 32)
      expect { described_class.check_encryption_keys!(bad) }.
        to raise_error(/ActiveRecord::Encryption/)
    end

    it 'accepts configured keys' do
      good = Struct.new(:primary_key, :deterministic_key,
                        :key_derivation_salt).new('a' * 32, 'b' * 32, 'c' * 32)
      expect { described_class.check_encryption_keys!(good) }.not_to raise_error
    end
  end
end

RSpec.describe 'config/initializers/production_safety.rb' do
  let(:initializer) do
    Rails.root.join('config/initializers/production_safety.rb').to_s
  end

  it 'checks admin auth at boot and resolved secrets after initialisation' do
    allow(Rails.env).to receive(:production?).and_return(true)
    allow(Rails.application.config).to receive(:after_initialize).and_yield
    allow(Rails.application).to receive(:secret_key_base).and_return('resolved')
    expect(ProductionSafety).to receive(:check_admin_auth!)
    expect(ProductionSafety).to receive(:check_secret!).with('resolved')
    expect(ProductionSafety).to receive(:check_incoming_email_secret!)
    expect(ProductionSafety).to receive(:check_encryption_keys!)
    load initializer
  end

  it 'skips the secret check under SECRET_KEY_BASE_DUMMY' do
    allow(Rails.env).to receive(:production?).and_return(true)
    allow(Rails.application.config).to receive(:after_initialize).and_yield
    stub_const('ENV', ENV.to_h.merge('SECRET_KEY_BASE_DUMMY' => '1'))
    allow(ProductionSafety).to receive(:check_admin_auth!)
    expect(ProductionSafety).not_to receive(:check_secret!)
    load initializer
  end

  it 'skips secret and encryption checks during config_files:set_credentials' do
    allow(Rails.env).to receive(:production?).and_return(true)
    allow(Rails.application.config).to receive(:after_initialize).and_yield
    allow(ProductionSafety).to receive(:current_rake_tasks).
      and_return(['config_files:set_credentials'])
    expect(ProductionSafety).to receive(:check_admin_auth!)
    expect(ProductionSafety).not_to receive(:check_secret!)
    expect(ProductionSafety).not_to receive(:check_incoming_email_secret!)
    expect(ProductionSafety).not_to receive(:check_encryption_keys!)
    load initializer
  end

  it 'does nothing outside production' do
    expect(ProductionSafety).not_to receive(:check_admin_auth!)
    expect(ProductionSafety).not_to receive(:check_secret!)
    load initializer
  end
end

RSpec.describe AlaveteliConfiguration, '.default_secret?' do
  it 'is true for the shipped default, the placeholder and short values' do
    expect(
      described_class.default_secret?(
        described_class::DEFAULTS[:SECRET_KEY_BASE]
      )
    ).to be true
    expect(
      described_class.default_secret?(
        'your secret key here, make it long and random'
      )
    ).to be true
    expect(described_class.default_secret?('a' * 63)).to be true
    expect(described_class.default_secret?('a' * 64)).to be false
    expect(described_class.default_secret?('')).to be true
    expect(described_class.default_secret?(nil)).to be true
  end

  it 'is false for a long random secret' do
    expect(described_class.default_secret?(SecureRandom.hex(64))).to be false
  end
end
