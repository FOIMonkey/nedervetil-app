require 'spec_helper'
require 'integration/alaveteli_dsl'

RSpec.describe 'Pro dashboard announcements', js: true do
  let(:pro_user) { FactoryBot.create(:pro_user) }

  before { with_feature_enabled(:alaveteli_pro) }

  let!(:announcements) do
    with_feature_enabled(:alaveteli_pro)
    pro_user
    %w[First Second Third].map do |title|
      travel 1.minute
      # Announcement fixes its allowed visibilities when the class loads,
      # which can be before Pro was switched on for this example.
      FactoryBot.build(:announcement, visibility: 'pro', title: title).
        tap { |announcement| announcement.save!(validate: false) }
    end
  end

  after { travel_back }

  def shown_title
    find('.carousel-item[aria-hidden="false"] .dashboard__announcement__title').
      text
  end

  it 'steps through the announcements, wrapping round' do
    using_pro_session(login(pro_user)) do
      visit alaveteli_pro_dashboard_path
      expect(shown_title).to eq('Third')
      expect(page).to have_css('.current-page', text: '1')
      expect(page).to have_css('.total-pages', text: '3')

      click_button 'next'
      expect(shown_title).to eq('Second')
      expect(page).to have_css('.current-page', text: '2')

      click_button 'prev'
      click_button 'prev'
      expect(shown_title).to eq('First')
      expect(page).to have_css('.current-page', text: '3')
    end
  end

  it 'dismisses one in the background and shows the next' do
    using_pro_session(login(pro_user)) do
      visit alaveteli_pro_dashboard_path
      within('.carousel-item[aria-hidden="false"]') { click_button 'Dismiss' }

      expect(shown_title).to eq('Second')
      expect(page).to have_css('.total-pages', text: '2')
      expect(page).to have_current_path(alaveteli_pro_dashboard_path)
      expect(eventually {
        announcements.last.dismissals.exists?(user: pro_user)
      }).to be true
    end
  end

  it 'goes once the last one is dismissed' do
    using_pro_session(login(pro_user)) do
      visit alaveteli_pro_dashboard_path
      3.times do
        within('.carousel-item[aria-hidden="false"]') { click_button 'Dismiss' }
      end
      expect(page).to have_no_css('.carousel')
    end
  end
end
