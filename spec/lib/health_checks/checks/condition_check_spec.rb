require 'spec_helper'

RSpec.describe HealthChecks::Checks::ConditionCheck do
  it { is_expected.to be_kind_of(HealthChecks::HealthCheckable) }

  it 'passes while its block returns true' do
    expect(described_class.new { true }).to be_ok
    expect(described_class.new { false }).not_to be_ok
    expect(described_class.new { nil }).not_to be_ok
  end
end
