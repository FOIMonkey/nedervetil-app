require 'spec_helper'

RSpec.describe AdminController do
  include_context 'consider all requests remote'
  controller(AdminController) {
      def index
        head :ok
      end
    }

  it 'permits a complete two-factor admin session' do
    sign_in FactoryBot.create(:admin_user)
    get :index
    expect(response).to have_http_status(:ok)
  end

  it 'does not trust cached legacy administrator flags or external-auth configuration' do
    allow(AlaveteliConfiguration).to receive(:skip_admin_auth).and_return(true)
    session[:using_admin] = 1
    session[:admin_name] = 'invented-emergency'
    session[:user_id] = users(:admin_user).id
    session[:user_login_token] = 'invented-legacy-token'
    get :index
    expect(response).to redirect_to(signin_path)
  end

  it 'rejects a Warden session with no full-authentication proof' do
    user = FactoryBot.create(:admin_user, :enable_totp)
    @request.env['warden'].set_user(user, scope: :user)
    get :index
    expect(response).to redirect_to(signin_path)
  end

  it 'rejects a complete ordinary session' do
    sign_in FactoryBot.create(:user)
    get :index
    expect(response).to have_http_status(:not_found)
  end

  it 'rejects an expired admin proof even with legacy flags' do
    sign_in FactoryBot.create(:admin_user)
    session[:using_admin] = 1
    travel 3.hours + 1.second do
      get :index
      expect(response).to redirect_to(signin_path)
    end
  end
end
