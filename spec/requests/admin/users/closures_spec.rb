require 'spec_helper'

RSpec.describe 'Admin user closures', type: :request do
  before { sign_in FactoryBot.create(:admin_user) }

  describe 'POST create' do
    let(:user) { FactoryBot.create(:user) }

    context 'with valid params for closing' do
      before { post admin_user_closure_path(user) }

      it 'closes the user' do
        expect(user.reload).to be_closed
      end

      it 'tells the admin that the user was closed' do
        expect(flash[:notice]).to eq('The user account was closed.')
      end

      it 'redirects to the user edit page' do
        expect(response).to redirect_to(edit_admin_user_path(user))
      end
    end

    context 'with invalid params' do
      it 'renders a 404' do
        get admin_user_path(user)
        expect(response).to have_http_status(:ok)

        post admin_user_closure_path(user_id: 0)
        expect(response).to have_http_status(:not_found)
      end
    end
  end
end
