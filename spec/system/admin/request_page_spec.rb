require 'spec_helper'
require 'integration/alaveteli_dsl'

RSpec.describe 'The admin request page', js: true do
  let(:admin) { FactoryBot.create(:admin_user) }

  it 'only lets the bulk destroy go once a message is ticked, with their ids' do
    info_request = FactoryBot.create(:info_request_with_incoming)
    message = info_request.incoming_messages.first
    using_session(login(admin)) do
      visit admin_request_path(info_request)
      button = find_button('Destroy selected messages', disabled: :all)
      expect(button).to be_disabled

      check "message_id_#{message.id}"
      expect(page).to have_button('Destroy selected messages', disabled: false)
      expect(find_by_id('ids', visible: :all).value).to eq(message.id.to_s)

      uncheck "message_id_#{message.id}"
      expect(page).to have_button('Destroy selected messages', disabled: true)
    end
  end

  it 'searches authorities in the move picker and shows a preview' do
    info_request = FactoryBot.create(:info_request)
    other_body = FactoryBot.create(:public_body, name: 'Cumbria County Council')
    using_session(login(admin)) do
      visit admin_request_path(info_request)
      within('#move-authority-disclosure') do
        find('summary').click
        fill_in 'public_body_url_name', with: 'Cumbria'
        click_button 'Cumbria County Council'
        expect(page).to have_css('.admin-move-preview',
                                 text: 'Cumbria County Council',
                                 visible: :visible)
        expect(page).to have_field('public_body_url_name',
                                   with: other_body.url_name)
        click_button 'Move request to authority'
      end
      expect(page).to have_text('Request has been moved to new body')
      expect(info_request.reload.public_body).to eq(other_body)
    end
  end

  it 'hides and restores a request inline with a reason' do
    info_request = FactoryBot.create(:info_request)
    using_session(login(admin)) do
      visit admin_request_path(info_request)
      within('#request-prominence') do
        find('summary', text: 'Hide from requester').click
        fill_in "prominence_reason_#{info_request.id}",
                with: 'Contains personal data'
        click_button 'Confirm hide'
      end
      expect(page).to have_text('Request hidden from the requester.')
      expect(info_request.reload.prominence).to eq('hidden')

      within('#request-prominence') do
        click_button 'Unhide for requester'
      end
      expect(page).to have_text('Request restored to the requester.')
      expect(info_request.reload.prominence).to eq('requester_only')
    end
  end

  it 'filters the chronological thread between messages and events' do
    info_request = FactoryBot.create(:info_request_with_incoming)
    using_session(login(admin)) do
      visit admin_request_path(info_request)
      within('#request-thread') do
        click_button "Events (#{info_request.info_request_events.count})"
        expect(page).to have_css('[data-thread-kind="event"]',
                                 visible: :visible)
        expect(page).to have_no_css('[data-thread-kind="incoming"]',
                                    visible: :visible)

        msg_count = info_request.outgoing_messages.count +
                    info_request.incoming_messages.count
        click_button "Messages (#{msg_count})"
        expect(page).to have_css('[data-thread-kind="incoming"]',
                                 visible: :visible)
        expect(page).to have_no_css('[data-thread-kind="event"]',
                                    visible: :visible)
      end
    end
  end
end
