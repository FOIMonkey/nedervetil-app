require 'spec_helper'
require 'integration/alaveteli_dsl'

RSpec.describe 'changing your email address' do
  let(:user) { FactoryBot.create(:user, email: 'old-owner@example.test') }

  def ask_to_change_email
    visit signchangeemail_path
    fill_in 'signchangeemail_password', with: 'jonespassword'
    fill_in 'signchangeemail_new_email', with: 'new-owner@example.test'
    click_button 'Send confirmation'
    expect(page).to have_content('Now check your email!')
  end

  def email_change_url
    ActionMailer::Base.deliveries.last.body.decoded[
      %r{https?://\S*/profile/change_email/confirm/\S+}
    ]
  end

  it 'notifies both addresses, requires authenticated confirmation, then signs out' do
    using_session(login(user)) do
      ask_to_change_email
      expect(ActionMailer::Base.deliveries.map(&:to)).
        to eq([['old-owner@example.test'], ['new-owner@example.test']])
      visit URI(email_change_url).request_uri
      expect(user.reload.email).to eq('old-owner@example.test')
      fill_in 'signchangeemail_password', with: 'jonespassword'
      click_button 'Change email address'
      expect(page).to have_current_path(signin_path)
      expect(user.reload.email).to eq('new-owner@example.test')
      expect(user.confirmed?).to eq(true)
    end
  end

  it 'cannot complete the email link from a signed-out browser' do
    using_session(login(user)) { ask_to_change_email }
    using_session('invented-other-browser') do
      visit URI(email_change_url).request_uri
      expect(page).to have_current_path(signin_path)
      expect(user.reload.email).to eq('old-owner@example.test')
    end
  end
end
