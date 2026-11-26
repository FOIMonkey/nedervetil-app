require 'spec_helper'

RSpec.describe 'general/_responsive_topnav' do
  let(:user) { FactoryBot.create(:user) }
  let(:pro_user) { FactoryBot.create(:pro_user) }

  before { view.extend(RequestJourney::NavigationHelper) }

  def render_view
    render partial: 'general/responsive_topnav'
  end

  def sign_in_as(account)
    assign :user, account
    allow(controller).to receive(:current_user).and_return(account)
    allow(view).to receive(:current_user).and_return(account)
  end

  # Every signed-in account has the inbox, whatever its role or the flag says.
  shared_examples 'the inbox navigation' do
    it 'shows a Home link to the inbox in place of Dashboard and Requests' do
      render_view
      expect(rendered).to have_css('#dashboard-link', text: 'Home')
      expect(rendered).to have_no_link('Dashboard')
      expect(rendered).to have_no_link('Requests')
    end
  end

  context 'when a Pro account is signed in', feature: :alaveteli_pro do
    before { sign_in_as(pro_user) }

    include_examples 'the inbox navigation'
  end

  context 'when an account without the Pro role is signed in' do
    before do
      sign_in_as(user)
    end

    include_examples 'the inbox navigation'
  end

  context 'when nobody is signed in' do
    before { allow(view).to receive(:current_user).and_return(nil) }

    it 'does not show the Home link' do
      render_view
      expect(rendered).to have_no_css('#dashboard-link')
    end
  end
end
