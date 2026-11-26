require 'spec_helper'
require 'integration/alaveteli_dsl'

RSpec.describe 'classifying a request' do
  let(:info_request) { FactoryBot.create(:info_request) }
  let(:user) { info_request.user }

  shared_examples_for 'authority is not subject to FOI law' do
    it 'does not include "By law"' do
      info_request.public_body.add_tag_if_not_already_present('foi_no')
      using_session(login(user)) do
        classify_request(info_request, classification)
        expect(page).to have_no_content('By law')
      end
    end
  end

  shared_examples_for 'authority is subject to FOI law' do
    it 'does includes the text "By law"' do
      using_session(login(user)) do
        classify_request(info_request, classification)
        expect(page).to have_content('By law')
      end
    end
  end

  shared_examples_for 'the donation link is configured' do
    it 'shows the donation link' do
      allow(AlaveteliConfiguration).to receive(:donation_url).
        and_return('http://donations.example.com')

      using_session(login(user)) do
        classify_request(info_request, classification)

        expect(page).
          to have_link('make a donation',
                       href: 'http://donations.example.com')
      end
    end
  end

  context 'when the request is internal' do
    describe 'the requestor tries to classify their request' do
      it 'sends an email including the message' do
        using_session(login(user)) do
          visit message_classification_path(
            url_title: info_request.url_title,
            described_state: 'requires_admin'
          )
          fill_in 'Please tell us more:',
                  with: "Okay. I don't quite understand."
          click_button 'Submit status and send message'
          expect(page).
            to have_content "Thank you! We'll look into what happened and " \
                            "try and fix it up."
        end

        is_expected.to have_sent_email.matching_body(/as needing admin/)
        is_expected.
          to have_sent_email.
            matching_body(/Okay. I don't quite understand./)
      end
    end
  end

  context 'marking request as error_message' do
    let(:classification) { 'error_message1' }

    it 'displays a thank you message post redirect' do
      using_session(login(user)) do
        classify_request(info_request, classification)

        # fill in form on the next page to supply more info about the error
        fill_in 'classification_message', with: 'test data'
        click_button('Submit status and send message')

        message = "Thank you! We'll look into what happened " \
                  "and try and fix it up."
        # redirect and receive thank you message
        expect(page).to have_content(message)
      end
    end

    it 'captures the message in the info_request_event log' do
      using_session(login(user)) do
        classify_request(info_request, classification)

        # fill in form on the next page to supply more info about the error
        fill_in 'classification_message', with: 'test data'
        click_button('Submit status and send message')

        last_event = info_request.reload.last_event
        expect(last_event.event_type).to eq('status_update')
        expect(last_event.params).
          to match(
            user: { gid: user.to_global_id.to_s },
            described_state: 'error_message',
            old_described_state: 'waiting_response',
            message: 'test data'
          )
      end
    end
  end

  context 'marking request as internal_review' do
    let(:classification) { 'internal_review1' }

    it 'displays a thank you message post redirect' do
      using_session(login(user)) do
        classify_request(info_request, classification)
        message = "Thank you! Hopefully your wait isn't too long."
        # redirect and receive thank you message
        expect(page).to have_content(message)
        expect(page).to have_link('details',
                                  href: unhappy_url(
                                    info_request,
                                          anchor: 'internal_review'
                                  ))
      end
    end
  end

  context 'marking request as not_held' do
    it 'is not a separate choice: the requester marks it as no information' do
      using_session(login(user)) do
        visit show_request_path(info_request.url_title, update_status: 1)
        expect(page).to have_field('rejected1')
        expect(page).to have_no_field('not_held1')
        classify_request(info_request, 'rejected1')
        expect(info_request.reload.described_state).to eq('rejected')
      end
    end
  end

  context 'marking request as partially_successful' do
    let(:classification) { 'partially_successful1' }

    it 'displays a thank you message post redirect' do
      using_session(login(user)) do
        classify_request(info_request, classification)
        message = "We're glad you got some of the information that you wanted"
        # redirect and receive thank you message
        expect(page).to have_content(message)
        expect(page).to have_no_link('make a donation')
      end
    end

    include_examples 'the donation link is configured'
  end

  context 'marking request as rejected' do
    let(:classification) { 'rejected1' }

    it 'displays a thank you message post redirect' do
      using_session(login(user)) do
        classify_request(info_request, classification)
        message = 'This request is now marked as no information'
        # redirect and receive thank you message
        expect(page).to have_content(message)
      end
    end
  end

  context 'marking request as requires_admin' do
    let(:classification) { 'requires_admin1' }

    it 'displays a thank you message post redirect' do
      using_session(login(user)) do
        classify_request(info_request, classification)

        # fill in form on the next page to supply more info about the error
        fill_in 'classification_message', with: 'test data'
        click_button('Submit status and send message')

        message = "Thank you! We'll look into what happened and try " \
                  "and fix it up."
        # redirect and receive thank you message
        expect(page).to have_content(message)
      end
    end

    it 'captures the message in the info_request_event log' do
      using_session(login(user)) do
        classify_request(info_request, classification)

        # fill in form on the next page to supply more info about the error
        fill_in 'classification_message', with: 'test data'
        click_button('Submit status and send message')

        last_event = info_request.reload.last_event
        expect(last_event.event_type).to eq('status_update')
        expect(last_event.params).
          to match(
            user: { gid: user.to_global_id.to_s },
            described_state: 'requires_admin',
            old_described_state: 'waiting_response',
            message: 'test data'
          )
      end
    end
  end

  context 'marking request as successful' do
    let(:classification) { 'successful1' }

    it 'displays a thank you message post redirect' do
      using_session(login(user)) do
        classify_request(info_request, classification)

        message = "We're glad you got all the information that you wanted."
        # redirect and receive thank you message
        expect(page).to have_content(message)
        expect(page).to have_no_content('annotation')
        expect(page).to have_no_link('make a donation')
      end
    end

    include_examples 'the donation link is configured'
  end

  context 'marking request as user_withdrawn' do
    let(:classification) { 'user_withdrawn1' }

    it 'displays a thank you message post redirect' do
      using_session(login(user)) do
        classify_request(info_request, classification)
        message = 'If you have not done so already, please write a ' \
                  'message below telling the authority that you have ' \
                  'withdrawn your request.'
        # redirect and receive thank you message
        expect(page).to have_content(message)
      end
    end
  end

  context 'marking request as waiting_clarification' do
    let(:classification) { 'waiting_clarification1' }

    it 'displays a thank you message post redirect' do
      using_session(login(user)) do
        classify_request(info_request, classification)
        message = 'Please write your follow up message containing the ' \
                  'necessary clarifications below.'
        # redirect and receive thank you message
        expect(page).to have_content(message)
      end
    end
  end

  context 'marking request as waiting_response' do
    let(:classification) { 'waiting_response1' }

    it 'displays a thank you message post redirect' do
      using_session(login(user)) do
        classify_request(info_request, classification)
        message = "Thank you! Hopefully your wait isn't too long"
        # redirect and receive thank you message
        expect(page).to have_content(message)
      end
    end

    include_examples 'authority is not subject to FOI law'

    include_examples 'authority is subject to FOI law'
  end

  context 'marking overdue request as waiting_response' do
    let(:classification) { 'waiting_response1' }

    before do
      travel_to(info_request.date_response_required_by + 2.days)
    end

    after do
      travel_back
    end

    it 'displays a thank you message post redirect' do
      using_session(login(user)) do
        classify_request(info_request, classification)
        message = "Thank you! Hope you don't have to wait much longer."
        # redirect and receive thank you message
        expect(page).to have_content(message)
      end
    end

    include_examples 'authority is not subject to FOI law'

    include_examples 'authority is subject to FOI law'
  end

  context 'marking very overdue request as waiting_responses' do
    let(:classification) { 'waiting_response1' }

    before do
      travel_to(info_request.date_very_overdue_after + 2.days)
    end

    after do
      travel_back
    end

    it 'displays a thank you message post redirect' do
      using_session(login(user)) do
        classify_request(info_request, classification)
        message = 'Thank you! Your request is long overdue'
        # redirect and receive thank you message
        expect(page).to have_content(message)
      end
    end
  end
end
