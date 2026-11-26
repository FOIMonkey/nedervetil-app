require 'spec_helper'
require 'integration/alaveteli_dsl'

RSpec.describe 'admin two factor authentication enforcement' do
  it 'keeps a password-proved unenrolled admin outside the admin interface' do
    admin = FactoryBot.create(:admin_user)
    visit signin_path
    fill_in :user_signin_email, with: admin.email
    fill_in :user_signin_password, with: 'jonespassword'
    click_button 'Sign in'
    expect(page).to have_current_path(new_one_time_password_path)
    visit admin_general_index_path
    expect(page).to have_current_path(signin_path)
  end

  it 'allows a fully authenticated enrolled admin into the admin interface' do
    using_session(login(FactoryBot.create(:admin_user, :enable_totp))) do
      visit admin_general_index_path
      expect(page).to have_current_path(admin_general_index_path)
    end
  end
end
