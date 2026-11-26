require 'spec_helper'

RSpec.describe 'Account pages', type: :request do
  # Signs in through the form and checks it worked, so that a refusal later
  # in the example is not a failed sign-in.
  def sign_in_as(user)
    sign_in(user)
    expect(response).to have_http_status(:see_other)
  end

  describe 'GET show' do
    let(:user) { FactoryBot.create(:user) }
    let(:admin) { FactoryBot.create(:admin_user) }

    it 'shows an account its own page' do
      sign_in_as user
      get show_user_path(user.url_name)
      expect(response).to have_http_status(:ok)
      page = Nokogiri::HTML(response.body)
      expect(page.at_css('h1.page-band__title').text).to eq('Account')
      expect(page.at_css('.account-band__sub').text).to include(user.name)
      expect(page.css('#user_change_password_email .account-settings__value').
               map(&:text)).to include(user.name, user.email)
    end

    it 'is not found for non-existent users' do
      user.destroy!
      get show_user_path(user.url_name)
      expect(response).to have_http_status(:not_found)
    end

    it 'is not found for unconfirmed users' do
      user = FactoryBot.create(:user, email_confirmed: false)
      get show_user_path(user.url_name)
      expect(response).to have_http_status(:not_found)
    end

    context 'when user is suspended' do
      it 'adds noindex, nofollow header' do
        user = FactoryBot.create(:user, :banned)
        sign_in_as admin
        get show_user_path(user.url_name)
        expect(response).to have_http_status(:ok)
        expect(response.headers['X-Robots-Tag']).to eq 'noindex, nofollow'
      end
    end

    context 'when redirecting a show request to a canonical url' do
      it 'redirects to lower case name if given one with capital letters' do
        sign_in_as users(:bob_smith_user)
        get '/user/Bob_Smith'
        expect(response).to redirect_to(show_user_path(url_name: 'bob_smith'))
      end

      it 'redirects a long non-canonical name that has a numerical ' \
         'suffix, retaining the suffix' do
        get '/user/Bob_SmithBob_SmithBob_SmithBob_S_2'
        expect(response).
          to redirect_to(show_user_path('bob_smithbob_smithbob_smithbob_s_2'))
      end

      it 'does not redirect a long canonical name that has a numerical ' \
         'suffix' do
        FactoryBot.create(:user,
                          name: 'Bob Smith Bob Smith Bob Smith Bob Smith')
        user =
          FactoryBot.create(:user,
                            name: 'Bob Smith Bob Smith Bob Smith Bob Smith')
        sign_in_as user
        get show_user_path('bob_smith_bob_smith_bob_smith_bo_2')
        expect(response).to have_http_status(:ok)
        expect(response.body).to include(user.email)
      end
    end

    context 'when viewing a profile' do
      it 'is not found when not logged in' do
        get show_user_profile_path(user.url_name)
        expect(response).to have_http_status(:not_found)
      end

      it 'shows the account its own settings, with no request list' do
        FactoryBot.create(:info_request, user: user, title: 'Some money?')
        sign_in_as user
        get show_user_profile_path(user.url_name)
        expect(response).to have_http_status(:ok)
        expect(response.body).to include('Change your password')
        expect(response.body).not_to include('Some money?')
        expect(response.body).not_to include('Freedom of Information requests')
      end
    end

    context 'when viewing requests' do
      it 'is not found when not logged in' do
        get show_user_requests_path(user.url_name)
        expect(response).to have_http_status(:not_found)
      end

      it 'sends the account to its inbox' do
        sign_in_as user
        get show_user_requests_path(user.url_name)
        expect(response).to redirect_to(alaveteli_pro_info_requests_path)
      end

      it 'is not found for another signed-in account' do
        other = FactoryBot.create(:user)
        sign_in_as other
        get show_user_requests_path(user.url_name)
        expect(response).to have_http_status(:not_found)

        get show_user_path(other.url_name)
        expect(response).to have_http_status(:ok)
      end

      it 'shows an admin the profile' do
        sign_in_as admin
        get show_user_requests_path(user.url_name)
        expect(response).to have_http_status(:ok)
        expect(response.body).to include(user.name)
        expect(response.body).not_to include('Freedom of Information requests')
      end
    end
  end

  describe 'GET tor' do
    before { get '/tor' }

    it 'returns a 403 status' do
      expect(response).to have_http_status(:forbidden)
    end

    it 'sets private, no-store cache headers' do
      expect(response.headers['Cache-Control']).to eq('private, no-store')
    end

    it 'renders a plain text message' do
      msg = 'Signups from Tor have been blocked due to extensive misuse. ' \
            'Please contact us if this is a problem for you.'
      expect(response.body).to eq(msg)
      expect(response.media_type).to eq('text/plain')
    end
  end

  describe 'POST set_receive_email_alerts' do
    it 'lets users turn their own email alerts on and off' do
      user = users(:silly_name_user)
      sign_in_as user
      expect(user.receive_email_alerts).to eq(true)
      post set_receive_email_alerts_path,
           params: { receive_email_alerts: 'false', came_from: '/' }
      expect(response).to redirect_to('/')
      expect(user.reload.receive_email_alerts).not_to eq(true)
    end
  end
end
