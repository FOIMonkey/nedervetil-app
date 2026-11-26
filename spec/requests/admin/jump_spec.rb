require 'spec_helper'

RSpec.describe 'Admin jump search', type: :request do
  let(:admin) { FactoryBot.create(:admin_user) }
  let(:user) do
    FactoryBot.create(:user, name: 'Rowan Patel', email: 'rowan@example.org')
  end
  let(:body) { FactoryBot.create(:public_body, name: 'Camden Council') }
  let(:info_request) do
    FactoryBot.create(:info_request,
                      user: user,
                      public_body: body,
                      title: 'Temporary accommodation rates')
  end
  let(:page) { Nokogiri::HTML(response.body) }

  it 'is not found for a non-admin user' do
    sign_in(user)
    get admin_jump_path, params: { q: 'Camden' }
    expect(response).to have_http_status(:not_found)
  end

  context 'as an admin' do
    before do
      info_request
      sign_in(admin)
    end

    it 'renders the full jump and all-tools page without JS' do
      get admin_jump_path
      expect(response).to have_http_status(:ok)
      expect(page.at_css('h1').text).to eq('Jump to record or tool')
      expect(page.at_css('#tools')).to be_present
    end

    it 'finds requests by #id, users by @email, authorities and tools' do
      get admin_jump_path, params: { q: "##{info_request.id}" }
      expect(response.body).to include(admin_request_path(info_request))

      get admin_jump_path, params: { q: '@rowan@example.org' }
      expect(response.body).to include(admin_user_path(user))

      get admin_jump_path, params: { q: 'Camden' }
      expect(response.body).to include(admin_body_path(body),
                                       admin_request_path(info_request))

      get admin_jump_path, params: { q: 'Censor' }
      expect(response.body).to include(admin_censor_rules_path)
    end

    it 'renders scoped picker results inside the requested turbo frame' do
      get admin_jump_path,
          params: { scope: 'bodies',
                    q: 'Camden',
                    frame: 'move_body_picker_results' },
          headers: { 'Turbo-Frame' => 'move_body_picker_results' }
      expect(response).to have_http_status(:ok)
      expect(response.headers['Cache-Control']).to eq('private, no-store')
      expect(response.headers['Vary']).to include('Turbo-Frame')
      expect(page.at_css('turbo-frame#move_body_picker_results')).to be_present
      expect(page.at_css('button.admin-picker__option')['data-record-value']).
        to eq(body.url_name)
    end
  end
end
