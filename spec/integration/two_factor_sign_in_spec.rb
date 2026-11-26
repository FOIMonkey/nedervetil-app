require 'spec_helper'
require 'integration/alaveteli_dsl'

RSpec.describe 'signing in with two factor authentication' do
  let(:user) { FactoryBot.create(:user, :enable_totp) }

  def submit_credentials(code = nil)
    visit signin_path
    within '#signin_form' do
      fill_in 'user_signin_email', with: user.email
      fill_in 'user_signin_password', with: 'jonespassword'
      fill_in 'user_signin_otp_attempt', with: code if code
      click_button 'Sign in'
    end
  end

  it 'keeps the user signed out until password and OTP are both correct' do
    submit_credentials
    expect(page).to have_css('#signin_form')
    expect(page).to have_no_css('#logged_in_bar .account-link')
    submit_credentials('invalid')
    expect(page).to have_content('was not recognised')
    submit_credentials(user.current_otp)
    expect(page).to have_content(user.name)
    expect(page).to have_no_content('You used a backup code')
  end

  it 'accepts a recovery code with the password and explains its consumption' do
    codes = user.generate_otp_backup_codes!
    user.save!
    submit_credentials(codes.first)
    expect(page).to have_content(user.name)
    expect(page).to have_content('You have 11 backup codes left')
    expect(page).to have_link('Generate new backup codes')
  end

  it 'warns when the last recovery code is consumed' do
    codes = user.generate_otp_backup_codes!
    user.otp_backup_codes = [user.otp_backup_codes.first]
    user.save!
    submit_credentials(codes.first)
    expect(page).to have_content('You used your last backup code')
    expect(page).to have_link('Generate new backup codes')
  end
end
