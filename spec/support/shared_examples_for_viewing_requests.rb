shared_examples_for 'keeps the request private' do
  it 'does not allow the user to publish a request' do
    using_pro_session(pro_user_session) do
      browse_pro_request(info_request.url_title)
      expect(page).to have_css('.request-foot',
                               text: 'Private: only you and the site’s ' \
                                     'admins can see it.')
      expect(page).to have_no_button('Publish request')
    end
  end
end

shared_examples_for 'allows followups' do
  it 'allows the user to send a follow up' do
    using_pro_session(pro_user_session) do
      browse_pro_request(info_request.url_title)
      first(:link, 'Send a followup').click
      expect(page).
        to have_content "Reply to #{info_request.public_body.name}"
      expect(page).to have_content "To their main FOI address."
      fill_in("Your reply", with: "Testing follow ups")
      click_button("Send reply")
      expect(page).
        to have_css(".request-feed", visible: :all, text: "Testing follow ups")
    end
  end
end

shared_examples_for 'a request with response' do
  before do
    incoming_message = FactoryBot.create(:plain_incoming_message,
                                         info_request: info_request)
    # A response leaves the request awaiting its status (InfoRequest#receive).
    info_request.update!(awaiting_description: true)
    info_request.log_event(
      'response',
      incoming_message_id: incoming_message.id
    )
    complete_reply_checks(info_request)
  end

  it 'allows the user to write a reply' do
    using_pro_session(pro_user_session) do
      browse_pro_request(info_request.url_title)
      first(:link, "Reply", exact: true).click
      expect(page).
        to have_content "Reply to #{info_request.public_body.name}"
      fill_in("Your reply", with: "Testing replies")
      click_button("Send reply")
      expect(page).
        to have_css(".request-feed", visible: :all, text: "Testing replies")
    end
  end

  it 'allows the user to download the entire request' do
    using_pro_session(pro_user_session) do
      browse_pro_request(info_request.url_title)
      expect { first(:link, "Download all").click }.
        to have_enqueued_job(InfoRequest::RegulatorPackJob)
      expect(page).to have_content('preparing your download')
    end
  end

  it 'allows the user to request an internal review' do
    using_pro_session(pro_user_session) do
      browse_pro_request(info_request.url_title)
      first(:link, "Ask for review").click
      expect(page).to have_css("h1", text: "Internal review")
      expect(page).to have_content "To #{info_request.public_body.name}"
      fill_in("Your review letter", with: "Testing internal reviews")
      click_button("Ask for review")
      expect(page).to have_css(".request-feed",
                               visible: :all, text: "Testing internal reviews")
    end
  end

  it 'allows the user to update the request status' do
    using_pro_session(pro_user_session) do
      browse_pro_request(info_request.url_title)
      expect(page).to have_css("summary", visible: :all, text: "Change status")
      # The current status shouldn't be checked, so that you can set it
      # again if you need too, e.g. to reset the awaiting response status
      waiting = find_field("I'm still waiting for my information",
                           visible: :all)
      expect(waiting).not_to be_checked
      click_button("Some of it")
      expect(info_request.reload.described_state).
        to eq("partially_successful")
      expect(page).to have_css(".receipt__got", text: "You got some of it.")
      # The form should still be there to allow us to go back if we
      # updated by mistake
      expect(page).to have_css("summary", visible: :all, text: "Change status")
    end
  end
end
