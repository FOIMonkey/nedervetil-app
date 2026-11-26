require 'spec_helper'
require 'integration/alaveteli_dsl'

RSpec.describe 'Requesting changes to a public body' do
  describe 'reporting an out of date email address' do
    let(:public_body) { FactoryBot.create(:public_body) }
    let(:user) { FactoryBot.create(:user) }

    describe 'when not logged in' do
      it "should not forget which public body you are updating during login" do
        # The authority page links to the form only for signed-in users.
        visit new_change_request_body_path(body: public_body.url_name)
        click_link("sign in")

        fill_in :user_signin_email, with: user.email
        fill_in :user_signin_password, with: "jonespassword"
        click_button "Sign in"

        expect(page).to have_content "Ask us to update the email address"
      end
    end
  end
end
