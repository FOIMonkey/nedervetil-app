require 'spec_helper'

RSpec.describe 'Inbox dashboard', type: :request do
  describe 'GET index' do
    let(:user) { FactoryBot.create(:pro_user) }

    before do
      FactoryBot.create(:info_request, user: user, title: 'Own grit bins')
      FactoryBot.create(:info_request, title: 'Someone else grit bins')
      sign_in user
      get alaveteli_pro_dashboard_path
    end

    it 'shows the dashboard' do
      expect(response).to have_http_status(:ok)
      expect(response.body).to include('Home')
    end

    it "shows the signed-in user's requests, and only theirs" do
      expect(response.body).to include('Own grit bins')
      expect(response.body).not_to include('Someone else grit bins')
    end

    it 'does not set new_pro_user in flash' do
      expect(flash[:new_pro_user]).to be_nil
    end
  end
end
