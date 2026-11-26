require 'spec_helper'

RSpec.describe 'Admin debug', type: :request do
  let(:admin_user) { FactoryBot.create(:admin_user) }

  before { sign_in admin_user }

  describe 'GET index' do
    it 'shows the debug page' do
      get admin_debug_index_path
      expect(response).to have_http_status(:ok)
      expect(response.body).to include('<h1>Debug</h1>')
      expect(response.body).to include("You are #{admin_user.url_name}")
    end

    it 'does not display request environment secrets' do
      cookies['synthetic'] = 'synthetic-secret-cookie'
      get admin_debug_index_path,
          params: { access_token: 'synthetic-access-token' }
      expect(response).to have_http_status(:ok)
      expect(response.body).to include("You are #{admin_user.url_name}")
      expect(response.body).not_to include('synthetic-secret-cookie',
                                           'synthetic-access-token',
                                           'Environment variables',
                                           '<h2>Session</h2>')
    end
  end
end
