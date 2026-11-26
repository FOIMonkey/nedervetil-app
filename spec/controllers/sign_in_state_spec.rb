require 'spec_helper'

RSpec.describe 'Who a request sees signed in', type: :controller do
  controller(ApplicationController) do
    def index
      head :ok
    end

    # Memoize current_ability first to verify sign-in/sign-out invalidates it.
    def create
      current_ability
      complete_authentication(User.find(params[:id]), two_factor: false)
    end

    def destroy
      current_ability
      clear_session_credentials
      head :ok
    end
  end

  let(:user) { FactoryBot.create(:user) }
  let(:info_request) { FactoryBot.create(:info_request, user: user) }

  def ability
    controller.send(:current_ability)
  end

  # Devise's default current_user invokes Warden strategies on every request;
  # Authentication::Session must read the session without authenticating.
  it 'asks the session who is signed in, and never tries to sign anyone in' do
    expect(request.env['warden']).not_to receive(:authenticate)

    get :index

    expect(controller.send(:current_user)).to be_nil
  end

  it 'sees the account that has just signed in' do
    post :create, params: { id: user.id }

    expect(controller.send(:current_user)).to eq(user)
    expect(controller.view_assigns['user']).to eq(user)
    expect(ability.can?(:read, info_request)).to be(true)
  end

  it 'sees nobody once the session is cleared' do
    sign_in user
    delete :destroy, params: { id: user.id }

    expect(controller.send(:current_user)).to be_nil
    expect(controller.view_assigns['user']).to be_nil
    expect(ability.can?(:read, info_request)).to be(false)
  end
end
