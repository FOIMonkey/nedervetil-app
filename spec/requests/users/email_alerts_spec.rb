require 'spec_helper'

RSpec.describe 'Disabling email alerts', type: :request do
  describe 'GET destroy' do
    context 'with a valid token' do
      let(:token) { 'valid' }

      before do
        allow(User::EmailAlerts).
          to receive(:disable_by_token).with(token).and_return(true)
        get users_disable_email_alerts_path(token: token)
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
        get users_disable_email_alerts_path(token: token)
      end
    end

    context 'with an invalid token' do
      before { get users_disable_email_alerts_path(token: 'invalid') }

      it 'tells the user the token was invalid' do
        expect(flash[:error]).to eq('Invalid token')
      end

      it 'redirects to the homepage' do
        expect(response).to redirect_to(root_path)
      end
    end
  end
end
