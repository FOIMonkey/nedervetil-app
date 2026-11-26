require 'spec_helper'

RSpec.describe 'Help from a help pack, in a browser', js: true do
  before do
    HelpSite.root = Rails.root.join('spec/fixtures/help_site').to_s
    @view_paths = HelpSiteController.view_paths
    HelpSiteController.prepend_view_path(
      Rails.root.join('spec/fixtures/help_site_views')
    )
  end

  after do
    HelpSiteController.view_paths = @view_paths
    HelpSite.reset_root!
  end

  describe 'the search box' do
    it 'finds answers as words are typed, and shows the sections again' do
      visit '/help'
      expect(page).to have_css('.help-find', visible: :visible)
      expect(page).to have_css('#help-browse .help-panel', count: 2)

      fill_in 'help-find', with: 'renew twice'
      expect(page).to have_css('#help-found .help-rows a', count: 1)
      expect(page).to have_no_css('#help-browse', visible: :visible)
      hit = find('#help-found .help-rows a')
      expect(hit['href']).to end_with('/help/borrowing/renewing')
      expect(hit).to have_css('small', text: 'Yes, twice.')

      fill_in 'help-find', with: ''
      expect(page).to have_no_css('#help-found .help-rows')
      expect(page).to have_css('#help-browse', visible: :visible)
    end

    it 'says when nothing matches, with a way to get in touch' do
      visit '/help'
      fill_in 'help-find', with: 'zeppelin'
      expect(page).to have_css('#help-found .help-none',
                               text: 'No matching answers for “zeppelin”')
      expect(find('#help-found .help-none a')['href']).
        to end_with('/help/contact')
    end

    it 'goes to the answer it finds' do
      visit '/help'
      fill_in 'help-find', with: 'open sunday'
      find('#help-found .help-rows a').click
      expect(page).to have_current_path('/help/visiting/opening-hours')
      expect(page).to have_css('h1', text: 'When is the library open?')
    end
  end

  describe 'the reply deadline checker' do
    it 'works the deadline out in place when the date changes' do
      visit '/help/visiting/opening-hours'
      find('details.help-date summary').click
      expect(page).to have_no_css('.help-date__result strong')

      # As choosing a day in the browser's date picker does.
      page.execute_script(<<~JS)
        const date = document.getElementById('help-date')
        date.value = '2026-03-02'
        date.dispatchEvent(new Event('change', { bubbles: true }))
      JS
      due = Deadlines::Calendar.
            working_days_after(Date.new(2026, 3, 2), 20, 'foi')
      expect(page).to have_css('.help-date__result strong',
                               text: due.strftime('%A'))
      expect(page).to have_css('details.help-date[open]')
      expect(page).to have_current_path('/help/visiting/opening-hours')
      expect(find_by_id('help-date').value).to eq('2026-03-02')
    end

    it 'leaves the keyboard in the date field when the answer arrives' do
      visit '/help/visiting/opening-hours'
      find('details.help-date summary').click
      find_by_id('help-date').send_keys(:up)
      expect(page).to have_css('.help-date__result strong')
      expect(page.evaluate_script('document.activeElement.id')).
        to eq('help-date')
    end
  end

  describe 'a marked word' do
    def explains_a_word
      expect(page).to have_no_css('.help-word-means')
      word = first('.help-word')
      expect(word['role']).to eq('button')
      word.click
      expect(word['aria-expanded']).to eq('true')
      expect(page).to have_css('.help-word-means', count: 1,
                                                   text: 'Kept past the date')
      word.click
      expect(word['aria-expanded']).to eq('false')
      expect(page).to have_no_css('.help-word-means')
    end

    it 'is explained in place, once, after Turbo visits and Back' do
      visit '/help/borrowing/how-long'
      explains_a_word

      # Left with a word explained, for Back to show Turbo's copy of it.
      first('.help-word').click
      expect(page).to have_css('.help-word-means', count: 1)
      expect_turbo_visit do
        find('.help-rows--next a').click
      end
      expect(page).to have_current_path('/help/borrowing/renewing')

      go_back_with_turbo
      expect(page).to have_current_path('/help/borrowing/how-long')
      explains_a_word
    end
  end
end
