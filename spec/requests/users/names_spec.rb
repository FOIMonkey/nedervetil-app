require 'spec_helper'

RSpec.describe 'Changing your name', type: :request do
  let(:page) { Nokogiri::HTML(response.body) }

  describe 'GET edit' do
    context 'without a logged in user' do
      it 'redirects to the home page' do
        get edit_users_name_path
        expect(response).to redirect_to(frontpage_path)
      end
    end

    context 'with a logged in user' do
      let(:user) { FactoryBot.create(:user, name: 'Alice Smith') }

      before do
        sign_in user
        get edit_users_name_path
      end

      it 'shows the form for the currently logged in user' do
        field = page.at_css('#change_name input[name="user[name]"]')
        expect(field['value']).to eq('Alice Smith')
      end

      it 'is successful' do
        expect(response).to be_successful
      end

      it 'renders the edit form' do
        expect(response.body).to include('Change your name used on')
        form = page.at_css('#change_name form')
        expect(form['action']).to eq(users_name_path)
      end
    end

    context 'with a banned user' do
      before { sign_in FactoryBot.create(:user, :banned) }

      it 'says the account is suspended instead of showing the form' do
        get edit_users_name_path
        expect(response.body).to include('Banned from this site')
        expect(page.at_css('#change_name')).to be_nil
        expect(response).to have_http_status(:ok)
      end
    end
  end

  describe 'PUT update' do
    context 'without a logged in user' do
      it 'redirects to the sign in page' do
        put users_name_path, params: { user: { name: 'Bobby' } }
        expect(response).to redirect_to(frontpage_path)
      end
    end

    context 'with a banned user' do
      let(:user) { FactoryBot.create(:user, :banned) }
      before { sign_in user }

      it 'says the account is suspended, without changing the name' do
        put users_name_path, params: { user: { name: 'Bobby' } }
        expect(response.body).to include('Banned from this site')
        expect(response).to have_http_status(:unprocessable_content)
        expect(user.reload.name).not_to eq('Bobby')
      end
    end

    context 'with valid attributes' do
      let(:user) { FactoryBot.create(:user) }
      before { sign_in user }

      it 'changes the name of the currently logged in user' do
        put users_name_path, params: { user: { name: 'Bobby' } }
        expect(response).
          to redirect_to(show_user_url(url_name: user.reload.url_name))
        expect(flash[:notice]).to eq('Name successfully updated.')
      end

      it 'updates the user name' do
        put users_name_path, params: { user: { name: 'Bobby' } }
        expect(user.reload.name).to eq('Bobby')
      end
    end

    context 'with bad parameters' do
      let(:user) { FactoryBot.create(:user, name: 'Alice Smith') }
      before { sign_in user }

      it 'refuses a form without its fields' do
        put users_name_path, params: { name: 'Bobby' }
        expect(response).to have_http_status(:bad_request)
        expect(user.reload.name).to eq('Alice Smith')
      end

      it 'can raise unpermitted parameter exception' do
        expect {
          put users_name_path,
              params: { user: { name: 'Updated text', role_ids: [1] } }
        }.to raise_error(ActionController::UnpermittedParameters)
      end
    end
  end
end
