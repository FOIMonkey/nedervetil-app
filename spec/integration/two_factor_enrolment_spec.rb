require 'spec_helper'
require 'integration/alaveteli_dsl'

RSpec.describe 'enrolling in two factor authentication' do
  let(:user) { FactoryBot.create(:user) }

  def begin_enrolment
    visit new_one_time_password_path
    fill_in 'Current password', with: 'jonespassword'
    click_button 'Continue'
    page.find('p code').text
  end

  it 'requires the password again, verifies TOTP, and displays recovery codes once' do
    using_session(login(user)) do
      secret = begin_enrolment
      expect(page).to have_css('svg')
      fill_in 'Authenticator code', with: ROTP::TOTP.new(secret).now
      click_button 'Enable two factor authentication'
      expect(page).to have_content('Save your recovery codes')
      codes = page.all('.backup-codes__list code').map(&:text)
      expect(codes.size).to eq(12)
      expect(codes).to all(match(/\A[0-9a-f]{32}\z/))
      expect(user.reload.otp_secret).to eq(secret)
      expect(user.totp?).to eq(true)
      expect(user.invalidate_otp_backup_code!(codes.first)).to eq(true)
      expect(user.reload.invalidate_otp_backup_code!(codes.first)).to eq(false)
      visit one_time_password_path
      expect(page).to have_content('Authenticator sign-in is enabled')
      expect(page).to have_no_content('Save your recovery codes')
      expect(page.html).not_to include(*codes)
    end
  end

  it 'leaves the user unenrolled after an incorrect code' do
    using_session(login(user)) do
      secret = begin_enrolment
      valid = ROTP::TOTP.new(secret).now
      fill_in 'Authenticator code',
        with: valid == '000000' ? '000001' : '000000'
      click_button 'Enable two factor authentication'
      expect(page).to have_content('Invalid or expired authentication code')
      expect(page).to have_content('Set up two factor authentication')
      expect(user.reload.totp?).to eq(false)
      expect(user.otp_secret).to be_nil
    end
  end
end
