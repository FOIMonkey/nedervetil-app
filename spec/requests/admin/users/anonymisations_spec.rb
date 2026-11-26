require 'spec_helper'

RSpec.describe 'Admin user anonymisations', type: :request do
  before { sign_in FactoryBot.create(:admin_user) }

  describe 'POST create' do
    let(:user) { FactoryBot.create(:user) }

    def name_removal_rules
      user.censor_rules.where(replacement: '[Name Removed]')
    end

    context 'on an open account' do
      before { post admin_user_anonymisation_path(user) }

      it 'redirects to the user edit page' do
        expect(response).to redirect_to(edit_admin_user_path(user))
      end

      it 'tells the admin that the user was not anonymised' do
        expect(flash[:error]).to eq(
          'Something went wrong. The user could not be anonymised.'
        )
        expect(name_removal_rules).to be_empty
      end
    end

    context 'with invalid params' do
      it 'renders a 404' do
        get admin_user_path(user)
        expect(response).to have_http_status(:ok)

        post admin_user_anonymisation_path(user_id: 0)
        expect(response).to have_http_status(:not_found)
      end
    end

    context 'on a closed account with no info requests' do
      before do
        user.close
        post admin_user_anonymisation_path(user)
      end

      it 'tells the admin that the user was not anonymised' do
        expect(flash[:error]).to eq(
          'Something went wrong. The user could not be anonymised.'
        )
        expect(name_removal_rules).to be_empty
      end
    end

    context 'on a closed account with info requests' do
      before do
        FactoryBot.create(:info_request, user: user)
        user.close
        post admin_user_anonymisation_path(user)
      end

      it 'anonymises the user' do
        expect(name_removal_rules).not_to be_empty
      end

      it 'tells the admin that the user was anonymised' do
        expect(flash[:notice]).to eq('The user was anonymised.')
      end

      it 'redirects to the user edit page' do
        expect(response).to redirect_to(edit_admin_user_path(user))
      end
    end
  end
end
