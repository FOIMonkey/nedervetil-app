require 'spec_helper'

RSpec.describe AlaveteliPro::BaseController do
  controller(AlaveteliPro::BaseController) do
    def index
      head :ok
    end

    def create
      head :ok
    end
  end

  # Every inbox action inherits the require_inbox_sign_in before_action.
  describe '#require_inbox_sign_in' do
    context 'when nobody is signed in' do
      it 'redirects to the sign-in page' do
        get :index
        expect(@response.redirect_url).
          to match(/http:\/\/test\.host\/profile\/sign_in/)
      end

      it 'asks to sign in for a form sent as well, not a 404' do
        post :create
        expect(@response.redirect_url).
          to match(/http:\/\/test\.host\/profile\/sign_in/)
      end
    end

    it 'is private, not an action' do
      expect(controller.public_methods).not_to include(:require_inbox_sign_in)
    end

    context 'when an account without the Pro role is signed in' do
      let(:user) { FactoryBot.create(:user) }

      before do
        sign_in user
      end

      it 'serves the page' do
        get :index
        expect(@response.status).to be 200
      end
    end

    context 'when a Pro account is signed in' do
      let(:user) { FactoryBot.create(:pro_user) }

      before { sign_in user }

      it 'serves the page' do
        get :index
        expect(@response.status).to be 200
      end
    end
  end
end
