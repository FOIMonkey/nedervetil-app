require 'spec_helper'
require 'integration/alaveteli_dsl'

# The find-an-authority and new request pages, whose scripts were inline
# jQuery with the debounce plugin.
RSpec.describe 'Starting a request', js: true do
  let(:body) { public_bodies(:geraldine_public_body) }

  it 'warns once the request gets long' do
    visit new_request_to_body_path(url_name: body.url_name)
    note = find('.message-text-length', visible: :all)
    expect(note.text).to eq('')

    fill_in 'Your request', with: 'x' * 801
    expect(page).to have_css('.message-text-length.text-length-l',
                             text: 'Getting long')

    fill_in 'Your request', with: 'x' * 2001
    expect(page).to have_css('.message-text-length.text-length-xl',
                             text: 'Very long')
  end

  it 'finds authorities as their name is typed', search_index: true do
    visit select_authority_path
    find_by_id('query').send_keys('Geraldine')
    within('#typeahead_response') do
      expect(page).to have_content(body.name)
    end
    expect(page).to have_current_path(select_authority_path)
  end

  # The results are a Turbo Frame that sends its links to the whole page.
  it 'opens a found authority in the whole page, not in the results', search_index: true do
    visit select_authority_path
    find_by_id('query').send_keys('Geraldine')
    within('#typeahead_response') do
      expect(page).to have_content(body.name)
      first('a[href]').click
    end
    expect(page).to have_no_current_path(select_authority_path)
  end
end
