require 'spec_helper'

RSpec.describe 'Admin user sign ins', type: :request do
  # The admin's own sign-in comes first, before retention is turned on, so
  # it adds no row of its own.
  before { sign_in FactoryBot.create(:admin_user) }

  let(:page) { Nokogiri::HTML(response.body) }

  def listed_users
    page.css('#sign-ins tbody tr td:first-child a[href^="/admin/users/"]').
      map { |link| link['href'] }
  end

  def user_links(sign_ins)
    sign_ins.map { |sign_in| admin_user_path(sign_in.user) }
  end

  describe 'GET index' do
    let!(:sign_ins) do
      allow(AlaveteliConfiguration).
        to receive(:user_sign_in_activity_retention_days).and_return(1)
      FactoryBot.create_list(:user_sign_in, 3)
    end

    before { get admin_sign_ins_path }

    it 'shows the sign ins page' do
      expect(response).to have_http_status(:ok)
      expect(page.at_css('title').text).to include('Listing user sign ins')
      expect(page.css('h1').map { |h| h.text.strip }).
        to include('Listing user sign ins')
    end

    it 'lists the sign ins' do
      expect(listed_users).to match_array(user_links(sign_ins))
    end

    context 'with a search query' do
      let!(:search_target) do
        FactoryBot.create(:user_sign_in, ip: '9.9.9.9')
      end

      before { get admin_sign_ins_path, params: { query: '9.9.9.9' } }

      it 'filters signins by the query' do
        expect(listed_users).to match_array(user_links([search_target]))
      end
    end
  end
end
