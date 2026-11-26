require 'spec_helper'
require 'integration/alaveteli_dsl'

RSpec.describe 'disabling optional two factor authentication' do
  let(:user) { FactoryBot.create(:user, :enable_totp) }

  it 'requires the current password and a fresh second factor, then signs out' do
    using_session(login(user)) do
      visit one_time_password_path
      fill_in 'Current password', with: 'jonespassword'
      fill_in 'Authenticator code or recovery code', with: 'invalid'
      click_button 'Disable two factor authentication'
      expect(page.status_code).to eq(422)
      expect(user.reload.totp?).to eq(true)
      visit one_time_password_path
      fill_in 'Current password', with: 'jonespassword'
      codes = user.generate_otp_backup_codes!
      user.save!
      fill_in 'Authenticator code or recovery code', with: codes.first
      click_button 'Disable two factor authentication'
      expect(page).to have_current_path(signin_path)
      expect(user.reload.totp?).to eq(false)
      expect(user.otp_secret).to be_nil
      expect(user.otp_backup_codes).to be_empty
    end
  end
end
