require 'spec_helper'
require 'integration/alaveteli_dsl'

RSpec.describe "Signing in" do
  let(:user) { FactoryBot.create(:user) }

  def try_login(user, options = {})
    default_options = { email: user.email,
                        password: 'jonespassword' }
    options = default_options.merge(options)
    login_url = '/profile/sign_in'
    login_url += "?r=#{options[:redirect]}" if options[:redirect]
    visit login_url
    within '#signin_form' do
      fill_in "Your e-mail:", with: options[:email]
      fill_in "Password:", with: options[:password]
      click_button "Sign in"
    end
  end

  it "shows you an error if you get the password wrong" do
    try_login(user, { password: 'badpassword' })
    expect(page).
      to have_content('The email, password or authentication code ' \
                      'was not recognised')
  end

  it "shows you an error if you get the email wrong" do
    try_login(user, { email: 'wrong@localhost' })
    expect(page).
      to have_content('The email, password or authentication code ' \
                      'was not recognised')
  end

  context 'when you give the right credentials' do
    it 'logs you in' do
      try_login(user, { redirect: '/list' })
      expect(page).
        to have_content user.name
    end

    it 'records your IP when configured' do
      allow(AlaveteliConfiguration).
        to receive(:user_sign_in_activity_retention_days).and_return(1)
      expect { try_login(user) }.to change { user.sign_ins.count }.from(0).to(1)
    end

    it 'does not record your IP when not configured' do
      allow(AlaveteliConfiguration).
        to receive(:user_sign_in_activity_retention_days).and_return(0)
      expect { try_login(user) }.not_to(change { user.sign_ins.count })
    end

    it "it redirects to the redirect path" do
      try_login(user, { redirect: '/help/about' })
      expect(page).
        to have_current_path '/help/about'
    end

    it 'does not redirect to another domain' do
      try_login(user, { redirect: 'http://bad.place.com/help/about' })
      expect(page).
        to have_current_path(Authentication::ReturnPath::DEFAULT)
    end

    it 'signs you out when the account is closed' do
      try_login(user, { redirect: '/list' })
      expect(page).to have_content user.name

      user.close!

      visit '/list'
      expect(page).to have_current_path('/documents')
      expect(page).to have_no_content user.name
    end

    context 'if an account is not confirmed' do
      let(:user) { FactoryBot.create(:unconfirmed_user) }

      it 'does not sign in or send a confirmation from a failed password form' do
        user
        ActionMailer::Base.deliveries.clear
        try_login(user)
        expect(page).to have_css('#signin_form')
        expect(page).to have_no_css('#logged_in_bar .account-link')
        expect(ActionMailer::Base.deliveries).to be_empty
      end
    end
  end

  # A requester's profile is theirs alone, so once signed out it answers 404;
  # signing out from it must not go back there.
  describe 'signing out' do
    it 'goes to the home page from a page only you could see' do
      try_login(user)
      visit show_user_profile_path(url_name: user.url_name)
      visit signout_path
      expect(page).to have_css('#logged_in_bar .account-link')
      click_button 'Sign out'
      expect(page).to have_current_path(frontpage_path)
      expect(page.status_code).to eq(200)

      visit show_user_profile_path(url_name: user.url_name)
      expect(page.status_code).to eq(404)
    end
  end
end
