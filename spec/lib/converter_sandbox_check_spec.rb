require 'spec_helper'

RSpec.describe ConverterSandboxCheck do
  describe '.verify!' do
    it 'allows any mode in development and test' do
      %w[development test].each do |env|
        expect { described_class.verify!(env: env, mode: :off) }.
          not_to raise_error
      end
    end

    it 'allows production when the sandbox is required' do
      expect { described_class.verify!(env: 'production', mode: :required) }.
        not_to raise_error
    end

    it 'refuses production with the sandbox off, missing or mistyped' do
      %i[off invalid].each do |mode|
        expect { described_class.verify!(env: 'production', mode: mode) }.
          to raise_error(AlaveteliSandbox::ConfigurationError,
                         /requires SANDBOX_CONVERTERS: required.*#{mode}/)
      end
    end

    it 'refuses any other non-development environment' do
      expect { described_class.verify!(env: 'staging', mode: :off) }.
        to raise_error(AlaveteliSandbox::ConfigurationError)
    end
  end
end
