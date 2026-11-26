require 'spec_helper'
require 'integration/alaveteli_dsl'

RSpec.describe "creating requests in alaveteli_pro" do
  context "when writing a new request from scratch" do
    let!(:public_body) { FactoryBot.create(:public_body, name: 'example') }
    let!(:pro_user) { FactoryBot.create(:pro_user) }
    let!(:pro_user_session) { login(pro_user) }

    def write_pro_request(public_body)
      visit new_alaveteli_pro_info_request_path
      expect(page).to have_content "Who holds it?"

      fill_in "Authority", with: public_body.name
      click_button "Find"
      within ".authority-results" do
        click_link public_body.name
      end

      fill_in "What is it about?", with: "Does the pro request form work?"
      click_button "Check publications"
      fill_in "Your request", with: "A very short letter."
    end

    def letter(middle)
      "Dear #{public_body.name},\n\n#{middle}\n\n" \
        "Yours faithfully,\n\n#{pro_user.name}"
    end

    it 'does not link to the batch request form' do
      using_pro_session(pro_user_session) do
        # New request form
        stub_typeahead_results(items: [public_body], total: 1)
        write_pro_request(public_body)
        expect(page).to have_no_content("start a batch request")
        expect(page).to have_no_link(
          href: alaveteli_pro_batch_request_authority_searches_path
        )
      end
    end

    it "allows us to save a draft" do
      using_pro_session(pro_user_session) do
        # New request form
        stub_typeahead_results(items: [public_body], total: 1)
        write_pro_request(public_body)
        click_button "Save draft"

        # Redirected back to new request form
        drafts = DraftInfoRequest.
                 where(title: "Does the pro request form work?")
        expect(drafts).to exist
        draft = drafts.first
        expect(draft.body).to eq letter("A very short letter.")

        expect(page).to have_content("Draft saved.")
        expect(page).to have_css(".flow-facts",
                                 text: "Only you and the site’s admins " \
                                       "can see it.")

        # The page should pre-fill the form with data from the draft
        expect(page).to have_css(".request-sheet__to",
                                 text: "To #{public_body.name}")
        expect(page).to have_field("Subject",
                                   with: "Does the pro request form work?")
        expect(page).to have_field("Your request",
                                   with: "A very short letter.")
      end
    end

    it "allows us to preview the request" do
      using_pro_session(pro_user_session) do
        # New request form
        stub_typeahead_results(items: [public_body], total: 1)
        write_pro_request(public_body)
        click_button "Check and send"

        # Preview page
        drafts = DraftInfoRequest.
                 where(title: "Does the pro request form work?")
        expect(drafts).to exist

        expect(page).to have_css("h1", text: "Check and send")
        # The fact there's a draft should be hidden from the user
        expect(page).to have_no_content("Draft saved.")

        expect(page).to have_content("To #{public_body.name}")
        expect(page).to have_css(".request-sheet__subject",
                                 text: "Does the pro request form work?")
        expect(page).to have_content("A very short letter.")
        expect(page).to have_css(".flow-facts",
                                 text: "Only you and the site’s admins " \
                                       "can see it.")
      end
    end

    it 'does not render HTML on the preview page' do
      public_body.update_attribute(:name, "Test's <sup>html</sup> authority")
      using_pro_session(pro_user_session) do
        visit show_public_body_path(url_name: public_body.url_name)
        click_link("Make request to #{public_body.name}")
        fill_in 'What is it about?', with: "HTML test"
        click_button "Check publications"
        fill_in "Your request", with: "A very short letter."
        click_button "Check and send"

        expect(page).to have_css("h1", text: "Check and send")
        expect(page).to have_content("Dear Test's <sup>html</sup> authority")
      end
    end

    it "allows us to send the request" do
      using_pro_session(pro_user_session) do
        # New request form
        stub_typeahead_results(items: [public_body], total: 1)
        write_pro_request(public_body)
        click_button "Check and send"

        # Preview page
        click_button "Send request"

        # Request page
        expect(page).
          to have_css("h1", text: "Does the pro request form work?")

        drafts = DraftInfoRequest.
                 where(title: "Does the pro request form work?")
        expect(drafts).not_to exist

        info_requests = InfoRequest.
                        where(title: "Does the pro request form work?")
        expect(info_requests).to exist

        info_request = info_requests.first

        expect(info_request.prominence).to eq 'requester_only'

        expect(info_request.outgoing_messages.length).to eq 1
        expect(info_request.outgoing_messages.first.body).
          to eq letter("A very short letter.")

        deliveries = ActionMailer::Base.deliveries
        expect(deliveries.size).to eq(1)
        mail = deliveries[0]
        expect(mail.body).to match(/A very short letter\./)
        expect(mail.subject).to match(
          /Freedom of Information request - Does the pro request form work\?/
        )
        expect(mail.to).to eq([public_body.request_email])
      end
    end

    it "allow us to edit a request after previewing" do
      using_pro_session(pro_user_session) do
        # New request form
        stub_typeahead_results(items: [public_body], total: 1)
        write_pro_request(public_body)
        click_button "Check and send"

        # Preview page
        click_link "Write request"

        # New request form again
        # The page should pre-fill the form with data from the draft
        expect(page).to have_css(".request-sheet__to",
                                 text: "To #{public_body.name}")
        expect(page).to have_field("Subject",
                                   with: "Does the pro request form work?")
        expect(page).to have_field("Your request",
                                   with: "A very short letter.")

        fill_in "Your request", with: "A very short letter, edited."
        click_button "Save draft"

        # Redirected back to new request form
        drafts = DraftInfoRequest.
                 where(title: "Does the pro request form work?")
        expect(drafts).to exist
        draft = drafts.first
        expect(draft.body).to eq letter("A very short letter, edited.")

        expect(page).to have_content("Draft saved.")

        click_button "Check and send"

        # Preview page again
        expect(page).to have_css("h1", text: "Check and send")
        # The fact there's a draft should be hidden from the user
        expect(page).to have_no_content("Draft saved.")

        expect(page).to have_content("To #{public_body.name}")
        expect(page).to have_css(".request-sheet__subject",
                                 text: "Does the pro request form work?")
        expect(page).to have_content("A very short letter, edited.")
        expect(page).to have_css(".flow-facts",
                                 text: "Only you and the site’s admins " \
                                       "can see it.")
      end
    end

    it "shows errors if we leave fields blank" do
      using_pro_session(pro_user_session) do
        # New request form, which asks for the authority first
        visit new_alaveteli_pro_info_request_path
        expect(page).to have_content "Who holds it?"
        expect(page).to have_no_field "Your request"

        stub_typeahead_results(items: [public_body], total: 1)
        write_pro_request(public_body)
        fill_in "Subject", with: ""
        fill_in "Your request", with: ""
        click_button "Check and send"

        # New request form with errors
        expect(page).to have_content "Please enter a summary of your " \
                                     "request"
        expect(page).to have_content "Please enter your letter requesting " \
                                     "information"
      end
    end

    it "fills out the body with a template message" do
      using_pro_session(pro_user_session) do
        # New request form
        stub_typeahead_results(items: [public_body], total: 1)
        write_pro_request(public_body)
        expect(page).to have_css(".request-sheet__fixed",
                                 text: "Dear #{public_body.name},")
        expect(page).to have_css(".request-sheet__fixed",
                                 text: /Yours faithfully,\s*#{pro_user.name}/)
      end
    end

    it "saves the draft even if we leave fields blank" do
      using_pro_session(pro_user_session) do
        # New request form
        stub_typeahead_results(items: [public_body], total: 1)
        write_pro_request(public_body)
        fill_in "Subject", with: ""
        click_button "Save draft"

        # New request form with errors
        expect(page).to have_content "Draft saved."
        expect(page).to have_no_content "Please enter a summary of your " \
                                         "request"
        expect(page).to have_no_content "Please select an authority"
        expect(page).to have_no_content 'Please sign at the bottom with ' \
                                         'your name, or alter the "Yours ' \
                                         'faithfully," signature'
      end
    end

    it "redirects to the pro page if the user starts the normal process" do
      # Make a request in the normal way
      with_feature_enabled(:alaveteli_pro) do
        stub_typeahead_results(items: [public_body], total: 1)
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

        # Someone with an account goes on to the sign in page
        within('#content') { click_link 'Sign in' }
        within '#signin_form' do
          fill_in "Your e-mail:", with: pro_user.email
          fill_in "Password:", with: "jonespassword"
          click_button "Sign in"
        end

        # Full authentication claims the pending letter once into a draft.
        expect(DraftInfoRequest.count).to eq 1

        # Pro request form
        expect(page).to have_content('Your request is saved as a draft. ' \
                                     'Review it before sending.')
        expect(page).to have_css(".request-sheet__to",
                                 text: "To #{public_body.name}")
        expect(page).to have_field("Subject",
                                   with: "Why is your quango called Geraldine?")
        expect(page).to have_field("Your request",
                                   with: "This is a silly letter. " \
                                         "It is too short to be interesting.")

        click_button "Check and send"

        # Preview page
        click_button "Send request"

        # Request page
        expect(page).
          to have_css("h1", text: "Why is your quango called Geraldine?")
      end
    end
  end
end
