require 'spec_helper'
require 'integration/alaveteli_dsl'

RSpec.describe 'Admin split triage desk and Jump dialog', js: true do
  let(:admin) { FactoryBot.create(:admin_user) }

  it 'triages items in place inside the Today frame without a full load' do
    req_one = FactoryBot.create(:attention_requested_request,
                                title: 'First flagged request')
    req_two = FactoryBot.create(:attention_requested_request,
                                title: 'Second flagged request')

    using_session(login(admin)) do
      visit admin_general_index_path
      expect(page).to have_css('turbo-frame#triage_detail', text: req_two.title)

      marker = 'split-stay-on-page'
      page.execute_script("window.__triageMarker = #{marker.to_json}")

      triage_href = admin_triage_path('request', req_one.id)
      find("a.admin-triage-link[href='#{triage_href}']").click
      expect(page).to have_css('turbo-frame#triage_detail', text: req_one.title)
      expect(page.evaluate_script('window.__triageMarker')).to eq(marker)
    end
  end

  it 'opens the Jump dialog and searches live across records and tools' do
    target_req = FactoryBot.create(:info_request,
                                   title: 'Gritting salt reserves 2026')

    using_session(login(admin)) do
      visit admin_general_index_path
      find('#admin-bar a.admin-bar__jump').click
      expect(page).to have_css('dialog#admin-jump-dialog[open]')

      fill_in 'admin-jump-input', with: 'Gritting salt'
      expect(page).to have_css(
        'turbo-frame#admin_jump_results a.admin-jump__item',
        text: target_req.title
      )

      find_by_id('admin-jump-input').send_keys(:escape)
      expect(page).to have_no_css('dialog#admin-jump-dialog[open]')
    end
  end
end
