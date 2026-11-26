require 'spec_helper'
require 'integration/alaveteli_dsl'

RSpec.describe 'managing recovery codes' do
  let(:user) { FactoryBot.create(:user, :enable_totp) }

  it 'generates replacement codes after password and second-factor step-up' do
    using_session(login(user)) do
      visit one_time_password_path
      click_link 'Manage recovery codes'
      fill_in 'Current password', with: 'jonespassword'
      codes = user.generate_otp_backup_codes!
      user.save!
      fill_in 'Authenticator code or recovery code', with: codes.first
      click_button 'Generate new recovery codes'
      expect(page).to have_content('Save these codes somewhere safe')
      expect(page.all('.backup-codes__list code').size).to eq(12)
    end
  end

  it 'does not put submitted credentials into language links after regeneration' do
    allow(AlaveteliLocalization).to receive(:available_locales).
      and_return(%w[en cy])

    using_session(login(user)) do
      codes = user.generate_otp_backup_codes!
      user.save!
      visit one_time_password_backup_codes_path
      fill_in 'Current password', with: 'jonespassword'
      fill_in 'Authenticator code or recovery code', with: codes.first
      click_button 'Generate new recovery codes'

      expect(page).to have_css('#user_locale_switcher a')
      links = page.all('#user_locale_switcher a').map { |link| link[:href] }
      expect(links.join).not_to include('jonespassword', codes.first)
    end
  end

  it 'rejects an incorrect second factor without replacing any codes' do
    using_session(login(user)) do
      original = user.reload.otp_backup_codes
      visit one_time_password_backup_codes_path
      fill_in 'Current password', with: 'jonespassword'
      fill_in 'Authenticator code or recovery code', with: 'invalid'
      click_button 'Generate new recovery codes'
      expect(page.status_code).to eq(422)
      expect(user.reload.otp_backup_codes).to eq(original)
    end
  end
end
