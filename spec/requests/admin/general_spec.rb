require 'spec_helper'

RSpec.describe 'Admin home, timeline and statistics', type: :request do
  before { sign_in FactoryBot.create(:admin_user) }

  let(:page) { Nokogiri::HTML(response.body) }

  describe 'GET index' do
    before { InfoRequest.destroy_all }

    def request_links_in(list_id)
      page.css("##{list_id} .admin-rows__act a[href^='/admin/requests/']").
        map { |link| link['href'] }
    end

    def change_request_links_in(list_id)
      page.css("##{list_id} a").map { |link| link['href'] }.
        grep(%r{\A/admin/change_requests/\d+/edit})
    end

    it 'shows the things to do page' do
      get admin_general_index_path
      expect(response).to have_http_status(:ok)
      expect(page.at_css('h1').text).to eq('Things to do')
    end

    it 'does not list old unclassified requests, which are their ' \
       'requesters’ to classify' do
      old_request = FactoryBot.create(:old_unclassified_request)
      get admin_general_index_path
      expect(response.body).not_to include(old_request.title)
      expect(page.css('#public-request-things-to-do')).to be_empty
    end

    it 'lists requests that require admin' do
      requires_admin_request = FactoryBot.create(:requires_admin_request)
      get admin_general_index_path
      expect(request_links_in('requires-admin')).
        to eq([admin_request_path(requires_admin_request)])
    end

    it 'lists requests that have error messages' do
      error_message_request = FactoryBot.create(:error_message_request)
      get admin_general_index_path
      expect(request_links_in('error-messages')).
        to eq([admin_request_path(error_message_request)])
    end

    it 'lists requests flagged for admin attention' do
      attention_requested_request = FactoryBot.create(
        :attention_requested_request
      )
      get admin_general_index_path
      expect(request_links_in('attention-messages')).
        to eq([admin_request_path(attention_requested_request)])
    end

    it 'lists messages sent to the holding pen' do
      undeliverable = FactoryBot.
                        create(:incoming_message,
                               info_request: InfoRequest.holding_pen_request)
      get admin_general_index_path
      expect(page.css('#holding-pen .admin-rows__act a').map { _1['href'] }).
        to eq([admin_raw_email_path(undeliverable.raw_email_id)])
      expect(page.at_css('turbo-frame#triage_detail')).to be_present
    end

    it 'filters the Today desk by queue parameter' do
      FactoryBot.create(:incoming_message,
                        info_request: InfoRequest.holding_pen_request)
      FactoryBot.create(:attention_requested_request)
      get admin_general_index_path(queue: 'holding_pen')
      expect(page.at_css('#holding-pen')).to be_present
      expect(page.at_css('#attention-messages')).to be_nil
    end

    context 'when there are request tasks' do
      it 'shows the request tasks' do
        FactoryBot.create(:incoming_message,
                          info_request: InfoRequest.holding_pen_request)
        get admin_general_index_path
        expect(page.css('#public-request-things-to-do')).to be_present
        expect(response.body).not_to include('Nothing to place, fix or answer.')
      end
    end

    context 'when there are no request tasks' do
      it 'says there is nothing to do for requests' do
        get admin_general_index_path
        expect(page.css('#public-request-things-to-do')).to be_empty
        expect(response.body).to include('Nothing to place, fix or answer.')
      end
    end

    it 'lists blank contacts' do
      blank_contact = FactoryBot.create(:blank_email_public_body)
      get admin_general_index_path
      expect(page.css('#blank-contacts .admin-rows__title').map(&:text).join).
        to include(blank_contact.name)
      expect(page.css('#blank-contacts .admin-rows > li').size).to eq(1)
    end

    it 'limits blank contacts to 20' do
      FactoryBot.create_list(:blank_email_public_body, 25)
      get admin_general_index_path
      expect(page.css('#blank-contacts .admin-rows > li').size).to eq(20)
    end

    it 'lists new body requests' do
      add_body_request = FactoryBot.create(:add_body_request)
      get admin_general_index_path
      expect(change_request_links_in('new-authorities')).
        to eq([edit_admin_change_request_path(add_body_request)])
    end

    it 'lists body update requests' do
      update_body_request = FactoryBot.create(:update_body_request)
      get admin_general_index_path
      expect(change_request_links_in('update-authorities')).
        to eq([edit_admin_change_request_path(update_body_request)])
    end

    context 'when there are authority tasks' do
      it 'shows the authority tasks' do
        FactoryBot.create(:update_body_request)
        get admin_general_index_path
        expect(page.css('#authority-things-to-do')).to be_present
      end
    end

    context 'when there are no authority tasks' do
      it 'shows no authority tasks' do
        get admin_general_index_path
        expect(response).to have_http_status(:ok)
        expect(page.css('#authority-things-to-do')).to be_empty
      end
    end

    context 'when there is nothing to do' do
      it 'says nothing is waiting' do
        get admin_general_index_path
        expect(page.css('#public-request-things-to-do')).to be_empty
        expect(page.css('#authority-things-to-do')).to be_empty
        expect(page.at_css('.admin-lede').text).
          to include('Nothing is waiting.')
      end
    end

    context 'when there is something to do' do
      it 'does not say nothing is waiting' do
        FactoryBot.create(:attention_requested_request)
        get admin_general_index_path
        expect(page.css('#public-request-things-to-do')).to be_present
        expect(page.at_css('.admin-lede').text).
          not_to include('Nothing is waiting.')
      end
    end
  end

  describe 'GET timeline' do
    let(:editors) do
      ['Body editor two', 'Request editor two',
       'Body editor one', 'Request editor one']
    end

    before do
      info_request = FactoryBot.create(:info_request)
      public_body = FactoryBot.create(:public_body)
      info_request.log_event('edit', { editor: 'Request editor one' })
      public_body.update!(name: 'Changed name',
                          last_edit_editor: 'Body editor one')
      info_request.log_event('edit', { editor: 'Request editor two' })
      public_body.update!(name: 'Changed name again',
                          last_edit_editor: 'Body editor two')
    end

    # Each event starts with its time, so the text after each <time> belongs
    # to one event, in the order shown. A day's heading has a <time> too.
    def events
      response.body.split('<time ').drop(1).
        reject { |text| text.include?('class="timeline_day"') }
    end

    def editors_in_order(count)
      events.first(count).map do |event|
        editors.find { |editor| event.include?(editor) }
      end
    end

    def events_title
      page.at_css('h1').text.strip
    end

    it 'lists events in order of descending date' do
      get admin_timeline_path(all: 1)
      expect(editors_in_order(4)).to eq(editors)
    end

    it 'sets the title appropriately' do
      get admin_timeline_path(all: 1)
      expect(events_title).to eq('All events in the last 2 days')
    end

    context 'when start_date is set' do
      it 'sets the title appropriately' do
        get admin_timeline_path(all: 1, start_date: Time.utc(1970, 1, 1))
        expect(events_title).to eq('All events, all time')
      end
    end

    context 'when event_type is info_request_event' do
      before do
        get admin_timeline_path(all: 1, event_type: 'info_request_event')
      end

      it 'lists request events in order of descending date' do
        expect(editors_in_order(2)).
          to eq(['Request editor two', 'Request editor one'])
      end

      it 'sets the title appropriately' do
        expect(events_title).to eq('Request events in the last 2 days')
      end
    end

    context 'when event_type is authority_change' do
      before do
        get admin_timeline_path(all: 1, event_type: 'authority_change')
      end

      it 'lists authority versions in order of descending date' do
        expect(editors_in_order(2)).
          to eq(['Body editor two', 'Body editor one'])
      end

      it 'sets the title appropriately' do
        expect(events_title).to eq('Authority changes in the last 2 days')
      end
    end
  end

  describe 'GET stats' do
    def summary
      page.css('.hero-unit h2').map { _1.text.squish }
    end

    def requests_by_state
      page.css('.stats-row').map do |row|
        [row.at_css('.span4').text.strip,
         row.at_css('.label').text.strip.delete(',').to_i]
      end
    end

    it 'shows the number of public bodies' do
      get admin_stats_path
      expect(summary.first).to eq("#{PublicBody.count} public authorities")
    end

    it 'shows the number of requests' do
      get admin_stats_path
      expect(summary.second).to start_with("#{InfoRequest.count} requests,")
    end

    it 'shows the number of users' do
      get admin_stats_path
      expect(summary.third).to eq("#{User.count} users")
    end

    it 'shows the number of requests in each state' do
      InfoRequest.destroy_all

      FactoryBot.create_list(:successful_request, 8)
      FactoryBot.create_list(:info_request, 2)
      FactoryBot.create(:attention_requested_request)

      get admin_stats_path
      expect(requests_by_state.to_h).
        to eq({ 'successful' => 8,
                'waiting_response' => 2,
                'attention_requested' => 1 })
    end

    it 'lists the states in name order' do
      InfoRequest.destroy_all

      FactoryBot.create(:info_request)
      FactoryBot.create(:successful_request)
      FactoryBot.create(:attention_requested_request)

      get admin_stats_path
      expect(requests_by_state.map(&:first)).
        to eq(%w[attention_requested successful waiting_response])
    end
  end
end
