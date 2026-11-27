require 'spec_helper'

RSpec.describe 'Disabling email alerts', type: :request do
  let(:origin) { { 'Origin' => "http://#{host}" } }

  describe 'GET show' do
    it 'shows a confirmation button without disabling alerts on GET' do
      user = FactoryBot.create(:user, receive_email_alerts: true)
      token = User::EmailAlerts.token(user)

      get users_disable_email_alerts_path(token: token)

      expect(response).to have_http_status(200)
      expect(response.headers['Referrer-Policy']).to eq('strict-origin')
      expect(response.body).to include('Disable email alerts')
      expect(user.reload.receive_email_alerts).to be(true)
    end

    it 'rejects an invalid token' do
      get users_disable_email_alerts_path(token: 'invalid')

      expect(flash[:error]).to eq('Invalid token')
      expect(response).to redirect_to(root_path)
    end
  end

  describe 'POST destroy' do
    context 'with a valid token' do
      let(:token) { 'valid' }

      before do
        allow(User::EmailAlerts).
          to receive(:disable_by_token).with(token).and_return(true)
        post users_disable_email_alerts_path(token: token), headers: origin
      end

      it 'shows the alerts disabled page' do
        expect(response.body).to include('Email Alerts Disabled')
        expect(response.body).
          to include('Email alerts for things you follow have now been ' \
                     'disabled.')
      end

      it 'is successful' do
        expect(response).to have_http_status(200)
      end
    end

    context 'with an escaped token' do
      let(:token) { CGI.escape('123=') }

      it 'unescapes the token' do
        expect(User::EmailAlerts).to receive(:disable_by_token).with('123=')
        post users_disable_email_alerts_path(token: token), headers: origin
      end
    end

    context 'with an invalid token' do
      before do
        post users_disable_email_alerts_path(token: 'invalid'), headers: origin
      end

      it 'tells the user the token was invalid' do
        expect(flash[:error]).to eq('Invalid token')
      end

      it 'redirects to the homepage' do
        expect(response).to redirect_to(root_path)
      end
    end
  end
end
