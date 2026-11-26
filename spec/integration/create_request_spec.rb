require 'spec_helper'
require 'integration/alaveteli_dsl'

RSpec.describe "When creating requests" do
  let!(:admin_user) { FactoryBot.create(:admin_user) }
  let!(:public_body) { FactoryBot.create(:public_body, name: 'example') }
  let!(:admin_user_session) { login(admin_user) }

  def make_request_and_sign_up(public_body)
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
    [PendingRequestDraft.last, confirmation_url_from_email]
  end

  it 'never sends a request as an admin who opens its confirmation link' do
    stub_typeahead_results(items: [public_body], total: 1)
    pending, confirmation_url = make_request_and_sign_up(public_body)
    title = JSON.parse(pending.payload)['title']

    using_session(admin_user_session) do
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
    expect(admin_user.info_requests).to be_empty
  end

  context 'the authority name contains an apostrophe' do
    let(:user) { FactoryBot.create(:user) }
    let(:user_session) { login(user) }
    let(:public_body) do
      FactoryBot.create(:public_body, name: "Test's Authority <b>test</b>")
    end

    def write_request_to(public_body)
      visit show_public_body_path(url_name: public_body.url_name)
      click_link('Make request')
      fill_in 'What is it about?', with: 'HTML test'
      click_button('Check publications')
    end

    it 'does not HTML escape the apostrophe in the request form' do
      using_pro_session(user_session) do
        write_request_to(public_body)

        expect(page).to have_no_content "Test&#39;s Authority"
        expect(page).to have_content "Dear Test's Authority"
      end
    end

    it 'appends the user name' do
      using_pro_session(user_session) do
        write_request_to(public_body)

        expect(page.source).
          to include("Yours faithfully,<br><b>#{user.name}</b>")
      end
    end

    it 'handles other special characters correctly' do
      public_body.update_attribute(:name, 'Test ("special" chars)')
      using_pro_session(user_session) do
        write_request_to(public_body)

        expect(page).to have_content 'Dear Test ("special" chars)'
      end
    end

    it 'does not render authority name HTML on the preview page' do
      public_body.update_attribute(:name, "Test's <sup>html</sup> authority")
      using_pro_session(user_session) do
        write_request_to(public_body)
        fill_in 'outgoing_message_letter', with: 'Please send the HTML test.'
        click_button('Check and send')

        expect(page).to have_content("Dear Test's <sup>html</sup> authority")
      end
    end
  end
end
