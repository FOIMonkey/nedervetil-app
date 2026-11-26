require 'spec_helper'
require 'integration/alaveteli_dsl'

RSpec.describe 'Signing in before making a request', js: true do
  let(:user) { FactoryBot.create(:user) }

  before do
    allow(AlaveteliConfiguration).
      to receive(:force_registration_on_new_request).and_return(true)
  end

  # The fork's own navigation has no "Make request" link; a theme's may.
  def visit_with_make_request_link
    visit help_about_path
    page.execute_script(<<~JS)
      document.querySelector('#content').insertAdjacentHTML('afterbegin',
        '<a id="make-request-link" href="/select_authority">Make request</a>')
    JS
  end

  # Signed-in users visiting /select_authority redirect to the Pro form.
  def start_of_a_request
    new_alaveteli_pro_info_request_path
  end

  it 'signs in in a dialog, then goes on to start a request' do
    visit_with_make_request_link
    find_by_id('make-request-link').click
    expect(page).to have_css('dialog.signin-dialog[open]')

    within_frame(find('.signin-dialog__frame')) do
      within '#signin_form' do
        fill_in 'user_signin_email', with: user.email
        fill_in 'user_signin_password', with: 'jonespassword'
        click_button(name: 'commit')
      end
      expect(page).to have_css('p', exact_text: 'You are signed in.')
      click_link 'Continue'
    end

    expect(page).to have_current_path(start_of_a_request)
  end

  it 'moves between signing in and signing up inside the dialog' do
    visit_with_make_request_link
    find_by_id('make-request-link').click

    within_frame(find('.signin-dialog__frame')) do
      click_link 'Create an account'
      expect(page).to have_css('#signup_form')
      expect(page).to have_no_css('#banner')
      click_link 'Sign in'
      expect(page).to have_css('#signin_form')
      expect(page).to have_no_css('#banner')
    end
    expect(page).to have_css('dialog.signin-dialog[open]')
  end

  it 'stays on the page when the dialog is shut without signing in' do
    visit_with_make_request_link
    find_by_id('make-request-link').click
    find('.signin-dialog__close').click
    expect(page).to have_no_css('dialog.signin-dialog[open]')
    expect(page).to have_current_path(help_about_path)
  end
end
