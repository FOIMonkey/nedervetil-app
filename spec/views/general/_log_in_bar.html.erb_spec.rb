require 'spec_helper'

RSpec.describe 'general/_log_in_bar' do
  let(:user) { FactoryBot.create(:user) }
  let(:pro_user) { FactoryBot.create(:pro_user) }

  def render_view
    render partial: 'general/log_in_bar'
  end

  def sign_in_as(account)
    assign :user, account
    allow(controller).to receive(:current_user).and_return(account)
  end

  before do
    # A return path, if the view set one, would name this page.
    allow(view.request).to receive(:fullpath).and_return('/test/fullpath')
  end

  # The same menu for every account, whatever its role or the flag says.
  shared_examples 'the account menu' do
    it 'does not show "pro" next to the user name' do
      render_view
      expect(rendered).to have_no_css('.pro-pill')
    end

    it 'links to the profile, not a separate requests page' do
      render_view
      expect(rendered).to have_link('My profile')
      expect(rendered).to have_no_link('My requests')
    end

    it 'sets no return path, in the pro area or out of it' do
      [true, false].each do |in_pro_area|
        assign :in_pro_area, in_pro_area
        render_view
        expect(rendered).to have_link('Sign out', href: signout_path)
      end
    end
  end

  context 'when a Pro account is signed in', feature: :alaveteli_pro do
    before { sign_in_as(pro_user) }

    include_examples 'the account menu'
  end

  context 'when an account without the Pro role is signed in' do
    before do
      sign_in_as(user)
    end

    include_examples 'the account menu'
  end
end
