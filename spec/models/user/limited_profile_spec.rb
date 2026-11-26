require 'spec_helper'

RSpec.describe User::LimitedProfile do
  it 'module is included to User' do
    expect(User.ancestors).to include(User::LimitedProfile)
  end

  describe 'limited_profile?' do
    subject { user.limited_profile? }

    context 'when limited' do
      let(:user) { FactoryBot.create(:user, :limited) }
      it { is_expected.to eq(true) }
    end

    context 'when the internal_admin_user' do
      let(:user) { FactoryBot.create(:user, :limited, :internal_admin_user) }
      it { is_expected.to eq(false) }
    end

    context 'when an admin' do
      let(:user) { FactoryBot.create(:user, :limited, :admin) }
      it { is_expected.to eq(false) }
    end

    context 'when confirmed_not_spam' do
      let(:user) do
        FactoryBot.create(:user, :limited, confirmed_not_spam: true)
      end

      it { is_expected.to eq(false) }
    end

    context 'when there are info_requests and classifications' do
      let(:user) do
        FactoryBot.create(
          :user, :limited,
          info_requests_count: 1, status_update_count: 1
        )
      end

      it { is_expected.to eq(false) }
    end
  end
end
