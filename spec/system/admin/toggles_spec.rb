require 'spec_helper'
require 'integration/alaveteli_dsl'

RSpec.describe 'Admin native disclosures and the admin bar', js: true do
  let(:admin) { FactoryBot.create(:admin_user) }
  let(:info_request) { FactoryBot.create(:info_request) }

  it 'folds a native details drawer open and shut on Request #show' do
    using_session(login(admin)) do
      visit admin_request_path(info_request)
      drawer = find("details#metadata_#{info_request.id}")
      expect(drawer[:open]).to be_falsey

      drawer.find('summary').click
      expect(page).to have_css("details#metadata_#{info_request.id}[open]")
      expect(drawer).to have_link('Edit metadata', visible: :visible)

      drawer.find('summary').click
      expect(page).to have_no_css("details#metadata_#{info_request.id}[open]")
    end
  end

  it 'opens the native details ban menu on User #show' do
    user = FactoryBot.create(:user)
    using_session(login(admin)) do
      visit admin_user_path(user)
      expect(page).to have_css('#user-ban-menu')
      expect(page).to have_no_button('Ban for evading', visible: :visible)

      find('#user-ban-menu > summary').click
      expect(page).to have_button('Ban for evading', visible: :visible)
      expect(page).to have_button('Ban for spamming', visible: :visible)
    end
  end

  it 'switches locale tabs without legacy data-toggle markup' do
    body = FactoryBot.create(:public_body)
    using_session(login(admin)) do
      visit edit_admin_body_path(body)
      tabs = all('#div-locales a[role="tab"]')
      skip 'needs more than one locale' if tabs.size < 2

      tabs[1].click
      expect(tabs[1]['aria-selected']).to eq('true')
      expect(tabs[0]['aria-selected']).to eq('false')
    end
  end

  it 'opens and closes the admin bar Tools menu on admin and public pages' do
    using_session(login(admin)) do
      [admin_general_index_path, help_about_path].each do |path|
        visit path
        summary = find('#admin-bar summary.admin-bar__toggle')
        expect(page).to have_no_link('Holidays', visible: :visible)

        summary.click
        expect(page).to have_link('Holidays', visible: :visible)
        expect(page).to have_css('details.admin-bar__more[open]')

        summary.send_keys(:escape)
        expect(page).to have_no_css('details.admin-bar__more[open]')

        summary.click
        expect(page).to have_css('details.admin-bar__more[open]')
        find('#admin-bar .admin-bar__who').click
        expect(page).to have_no_css('details.admin-bar__more[open]')
      end
    end
  end
end
