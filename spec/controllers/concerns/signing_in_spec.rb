require 'spec_helper'

# A public method of a controller is an action: a route could reach it. None
# of the sign-in methods is a page, so none may be one.
RSpec.describe SigningIn do
  let(:sign_in_methods) do
    %w[modal_dialog? sign_page_layout sign_page_params
       clear_session_credentials complete_authentication
       after_sign_in_path_for]
  end

  it 'has no public method' do
    expect(described_class.public_instance_methods(false)).to be_empty
  end

  it 'adds no action to a controller' do
    [ApplicationController, Users::SessionsController,
     AlaveteliPro::DashboardController].each do |controller|
      expect(controller.action_methods.to_a & sign_in_methods).to be_empty
    end
  end

  it 'still gives pages the helpers they use' do
    expect(ApplicationController._helper_methods).
      to include(:sign_page_params, :current_user)
  end
end
