require 'spec_helper'
require 'integration/alaveteli_dsl'

RSpec.describe 'The site header', js: true do
  describe 'the account menu' do
    let(:user) { FactoryBot.create(:user) }

    it 'opens from the name, and shuts on Escape or a click elsewhere' do
      using_session(login(user)) do
        visit help_about_path
        link = find('#logged_in_bar .account-link')
        expect(link['role']).to eq('button')
        expect(page).to have_no_css('.logged-in-menu', visible: :visible)

        link.click
        expect(page).to have_css('.logged-in-menu', visible: :visible)
        expect(link['aria-expanded']).to eq('true')

        link.send_keys(:escape)
        expect(page).to have_no_css('.logged-in-menu', visible: :visible)
        focused = page.evaluate_script(
          'document.activeElement.classList.contains("account-link")'
        )
        expect(focused).to be true

        link.click
        # The demo theme's menu overlaps the heading. The footer provides
        # an unobscured outside target; this must dismiss without navigating.
        find_by_id('footer').click(x: 5, y: 5)
        expect(page).to have_current_path(help_about_path)
        expect(page).to have_no_css('.logged-in-menu', visible: :visible)
      end
    end

    it 'leaves the signed-out header alone' do
      visit help_about_path
      expect(page).to have_link('Sign in or sign up')
    end
  end

  describe 'the search on a phone' do
    before { page.current_window.resize_to(375, 800) }

    it 'puts the cursor in the field instead of searching for nothing' do
      visit help_about_path
      # Core's own header keeps the search in the phone menu.
      click_link 'Menu' if page.has_link?('Menu')
      within('#navigation_search_form') { click_button(type: 'submit') }
      expect(page).to have_current_path(help_about_path)
      expect(page.evaluate_script('document.activeElement.id')).
        to eq('navigation_search_button')
    end
  end
end
