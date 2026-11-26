require 'spec_helper'
require 'integration/alaveteli_dsl'

RSpec.describe "administering requests" do
  context 'when the admin user is a pro' do
    let!(:pro_admin_user) do
      pro_user = FactoryBot.create(:pro_user)
      pro_user.add_role :admin
      pro_user
    end
    let!(:pro_admin_user_session) { login(pro_admin_user) }

    context 'when the user being administered is a pro, as every account is' do
      let!(:public_body) do
        FactoryBot.create(:public_body,
                          name: 'example')
      end

      context "the admin user visits the non admin user's confirmation link" do
        # The replay used to run as whoever clicked the link. Admins never
        # send for users: with every account Pro, the request is dropped, and
        # nothing is made or offered as the admin's own.
        it 'never sends the request as the admin' do
          stub_typeahead_results(items: [public_body], total: 1)
          user = FactoryBot.build(:user)
          using_session(without_login) do
            visit select_authority_path
            within(:css, '#search_form') do
              fill_in 'query', with: public_body.name
              find_button('Search').click
            end
            within(:css, '.body_listing') do
              find_link('Make request').click
            end
            fill_in 'Summary', with: "Why is your quango called Geraldine?"
            fill_in 'Your request',
                    with: "This is a silly letter. It is too short to be " \
                          "interesting."
            find_button('Next step: preview your request').click
            find_button('Send request').click
            expect(page).to have_css('h1', text: 'Create an account')

            within '#signup_form' do
              fill_in "Your name:", with: user.name
              fill_in "Your e-mail:", with: user.email
              click_button "Sign up"
            end
            expect(page).to have_content('Check your email')
          end
          pending = PendingRequestDraft.last
          confirmation_url = confirmation_url_from_email
          title = JSON.parse(pending.payload)['title']

          using_pro_session(pro_admin_user_session) do
            expect {
              visit confirmation_url
              fill_in "confirm_user_password", with: "jonespassword"
              fill_in "confirm_user_password_confirmation",
                      with: "jonespassword"
              click_button 'Confirm email'
            }.not_to change(InfoRequest, :count)
            expect(page).to have_no_field(with: title)
          end
          expect(DraftInfoRequest.where(title: title)).to be_empty
          expect(pro_admin_user.info_requests).to be_empty
        end
      end
    end
  end
end
