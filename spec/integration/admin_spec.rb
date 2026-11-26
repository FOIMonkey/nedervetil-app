require 'spec_helper'
require 'integration/alaveteli_dsl'

RSpec.describe "When administering the site" do
  let(:admin_user) { FactoryBot.create(:admin_user) }
  let(:bob_smith_user) { FactoryBot.create(:user, name: 'Bob Smith') }
  let(:robin_user) { FactoryBot.create(:user, name: 'Robin') }

  before do
    allow(AlaveteliConfiguration).to receive(:skip_admin_auth).and_return(false)
    confirm(:admin_user)
    @admin = login(:admin_user)
  end

  it 'retains account administration without an impersonation action' do
    using_session(@admin) do
      visit admin_user_path(bob_smith_user)
      expect(page).to have_content('Bob Smith')
      expect(page).
        to have_no_link('Log in as Bob Smith (also confirms their email)')
    end
  end

  it 'denies administration to ordinary accounts' do
    using_session(login(robin_user)) do
      visit admin_user_path(bob_smith_user)
      expect(page.status_code).to eq(404)
    end
  end

  it "allows redelivery of an incoming message to a closed request" do
    # close request
    info_request = FactoryBot.create(:info_request_with_incoming)
    close_request(info_request)

    # check number of messages in holding pen and request
    expect(holding_pen_messages.length).to eq(0)
    expect(info_request.incoming_messages.length).to eq(1)

    # deliver an incoming message to the closed request -
    # it gets bounced to the holding pen
    receive_incoming_mail('incoming-request-plain.eml',
                          to: info_request.incoming_email,
                          from: "frob@nowhere.com")
    expect(holding_pen_messages.length).to eq(1)
    new_message = holding_pen_messages.first
    expect(info_request.incoming_messages.length).to eq(1)

    # redeliver the message
    using_session(@admin) do
      visit edit_admin_incoming_message_path(new_message)
      fill_in('Redeliver message to one or more other requests',
                with: info_request.url_title)
      find_button('Redeliver to another request').click
      expect(page).to have_current_path(
        admin_request_path(info_request), ignore_query: true
      )
    end

    # check number of messages in holding pen and request
    expect(info_request.reload.incoming_messages.length).to eq(2)
    expect(holding_pen_messages.length).to eq(0)
  end

  it "allows redelivery of an incoming message to more than one request" do
    # close request
    info_request = FactoryBot.create(:info_request_with_incoming)
    close_request(info_request)

    # check number of messages in holding pen and requests
    expect(holding_pen_messages.length).to eq(0)
    expect(info_request.incoming_messages.length).to eq(1)

    second_request = FactoryBot.create(:info_request_with_incoming)
    expect(second_request.incoming_messages.length).to eq(1)

    # deliver an incoming message to the closed request -
    # it gets bounced to the holding pen
    receive_incoming_mail('incoming-request-plain.eml',
                          to: info_request.incoming_email,
                          from: "frob@nowhere.com")
    expect(holding_pen_messages.length).to eq(1)
    new_message = holding_pen_messages.first

    # redeliver the message to two requests
    using_session(@admin) do
      visit edit_admin_incoming_message_path(new_message)
      fill_in('Redeliver message to one or more other requests',
                 with: "#{info_request.url_title},#{second_request.url_title}")
      find_button('Redeliver to another request').click
      expect(page).to have_current_path(
        admin_request_path(second_request), ignore_query: true
      )
    end

    # check number of messages in holding pen and requests
    expect(info_request.reload.incoming_messages.length).to eq(2)
    expect(second_request.reload.incoming_messages.length).to eq(2)
    expect(holding_pen_messages.length).to eq(0)
  end

  describe "the debug page" do
    it "should show the current user name" do
      using_session(@admin) do
        visit admin_debug_index_path
        expect(page).to have_content "joe_admin"
      end
    end

    it "should show the current Alaveteli version" do
      using_session(@admin) do
        visit admin_debug_index_path
        expect(page).to have_content ALAVETELI_VERSION
      end
    end
  end

  describe 'when administering the holding pen' do
    it "shows a rejection reason for an incoming message from an invalid address" do
      info_request = FactoryBot.create(
        :info_request,
        allow_new_responses_from: 'authority_only',
        handle_rejected_responses: 'holding_pen'
      )
      receive_incoming_mail('incoming-request-plain.eml',
                            to: info_request.incoming_email,
                            from: "frob@nowhere.com")
      using_session(@admin) do
        visit admin_raw_email_path last_holding_pen_mail
        expect(page).
          to have_content "Only the authority can reply to this request"
      end
    end
  end
end
