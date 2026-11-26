require 'spec_helper'

RSpec.describe 'Admin user suspensions', type: :request do
  before { sign_in FactoryBot.create(:admin_user) }

  describe 'POST create' do
    let(:user) { FactoryBot.create(:user) }

    context 'with valid params for banning' do
      before do
        post admin_user_suspension_path(user),
             params: { suspension_reason: 'Banned for spamming' }
      end

      it 'bans the user with the given reason' do
        expect(user.reload.ban_text).to eq('Banned for spamming')
        expect(user).to be_suspended
      end

      it 'tells the admin that the user was banned' do
        expect(flash[:notice]).to eq('The user was suspended.')
      end

      it 'redirects to the user page' do
        expect(response).to redirect_to(admin_user_path(user))
      end
    end

    context 'with invalid params' do
      it 'renders a 404' do
        get admin_user_path(user)
        expect(response).to have_http_status(:ok)

        post admin_user_suspension_path(user_id: 0)
        expect(response).to have_http_status(:not_found)
      end
    end

    context 'without a suspension_reason' do
      before { post admin_user_suspension_path(user) }

      it 'sets a default suspension reason' do
        default = 'Account suspended – Please contact us'
        expect(user.reload.ban_text).to eq(default)
      end
    end
  end
end
