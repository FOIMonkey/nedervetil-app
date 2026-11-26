require 'spec_helper'

RSpec.describe 'Request limit selection' do
  include_context 'with request limits off'

  let(:user) { FactoryBot.create(:user) }

  def refused?
    RequestLimits.refusal(user, :request).present?
  end

  def fill_daily_cap(ago: 2.minutes.ago)
    3.times do
      RequestLimits::Send.create!(user_id: user.id, kind: 'request',
                                  created_at: ago)
    end
  end

  # Leave the test-only override off to exercise the production selector.
  before do
    allow(Rails.env).to receive(:production?).and_return(true)
    allow(AlaveteliConfiguration).to receive(:enforce_request_limits).
      and_return(AlaveteliConfiguration::DEFAULTS.fetch(:ENFORCE_REQUEST_LIMITS))
  end

  it 'enforces the limits under the production defaults' do
    expect(AlaveteliConfiguration.enforce_request_limits).to eq(true)
    expect(RequestLimits).to be_enforced
    expect(refused?).to eq(false)
  end

  it 'refuses once the send log reaches the daily cap' do
    fill_daily_cap
    expect(refused?).to eq(true)
  end

  it 'allows a trusted account above the daily cap' do
    user.update!(trusted: true)
    fill_daily_cap
    expect(refused?).to eq(false)
  end

  it 'allows again once the send log is outside all windows' do
    fill_daily_cap(ago: 31.days.ago)
    expect(refused?).to eq(false)
  end

  [false, nil].each do |setting|
    context "with ENFORCE_REQUEST_LIMITS set to #{setting.inspect}" do
      before do
        allow(AlaveteliConfiguration).to receive(:enforce_request_limits).
          and_return(setting)
      end

      it 'allows anyone without reading the send log' do
        fill_daily_cap
        expect(RequestLimits).not_to be_enforced
        expect(RequestLimits::Send).not_to receive(:where)
        expect(refused?).to eq(false)
      end
    end
  end

  it 'does not enforce the limits outside production' do
    allow(Rails.env).to receive(:production?).and_return(false)

    expect(RequestLimits).not_to be_enforced
  end
end
