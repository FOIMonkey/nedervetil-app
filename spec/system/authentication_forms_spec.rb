require 'spec_helper'
require 'integration/alaveteli_dsl'

# Request specs spoof Origin; only a real browser applies Referrer-Policy to
# form-post Origin headers. Forgery protection is re-enabled because the test
# env disables it (which also skips the signed-out Origin check).
RSpec.describe 'Signed-out authentication forms in a browser', js: true do
  let(:user) { FactoryBot.create(:user) }

  around { |example| with_forgery_protection { example.run } }

  def sign_in(password)
    visit signin_path
    within '#signin_form' do
      fill_in 'Your e-mail:', with: user.email
      fill_in 'Password:', with: password
      click_button 'Sign in'
    end
  end

  it 'gives a wrong password its own message, not a refused form' do
    sign_in('badpassword')
    expect(page).to have_content(
      'The email, password or authentication code was not recognised'
    )
    expect(page).to have_no_content("couldn't be sent")
  end

  it 'signs in with the right password' do
    sign_in('jonespassword')
    expect(page).to have_css('#logged_in_bar a.account-link', visible: :all)
    expect(page).to have_no_content("couldn't be sent")
  end

  it 'changes the password from the mailed reset address' do
    token = user.send_reset_password_instructions
    visit edit_password_change_path(reset_password_token: token)
    fill_in 'New password', with: 'changed-invented-password'
    fill_in 'Confirm password', with: 'changed-invented-password'
    click_button 'Change password'
    expect(page).to have_content('Password changed. Please sign in.')
    expect(page).to have_no_content("couldn't be sent")
  end
end
