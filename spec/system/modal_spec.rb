require 'spec_helper'

# Core shows no modal; themes do, with the markup the modal controller
# documents. The spec puts that markup on a page.
RSpec.describe 'The modal controller', js: true do
  def add_modal(attributes = '')
    page.execute_script(<<~JS)
      document.querySelector('#content').insertAdjacentHTML('beforeend', `
        <div data-controller="modal" #{attributes}>
          <button type="button" id="opener" data-action="modal#open">Open</button>
          <div class="modal-content modal-hidden" aria-hidden="true"
               data-modal-target="content">
            <button type="button" class="button modal-close" data-action="modal#close">Close</button>
            <div class="modal-container"><a href="#" id="inside">Inside</a></div>
          </div>
        </div>`)
    JS
  end

  it 'opens, keeps focus inside, and shuts on Escape back to the opener' do
    visit help_about_path
    add_modal
    click_button 'Open'
    expect(page).to have_css('.modal-content[aria-hidden="false"]')
    expect(page).to have_css('.modal-overlay')
    expect(page).to have_css('.modal-content .focus-trap-start', visible: :all)

    find_by_id('inside').send_keys(:escape)
    expect(page).
      to have_css('.modal-content[aria-hidden="true"]', visible: :all)
    expect(page).to have_no_css('.modal-overlay')
    expect(page).to have_css('#opener:focus')
  end

  it 'opens by itself when asked, and stays open on Escape when asked' do
    visit help_about_path
    add_modal('data-modal-auto-open-value="true" ' \
              'data-modal-click-outside-close-value="false"')
    expect(page).to have_css('.modal-content[aria-hidden="false"]')
    find_by_id('inside').send_keys(:escape)
    expect(page).to have_css('.modal-content[aria-hidden="false"]')
    click_button 'Close'
    expect(page).
      to have_css('.modal-content[aria-hidden="true"]', visible: :all)
  end
end
