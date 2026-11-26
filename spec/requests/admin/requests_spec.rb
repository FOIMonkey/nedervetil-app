require 'spec_helper'

RSpec.describe 'Admin requests', type: :request do
  let(:admin_user) { FactoryBot.create(:admin_user) }

  def page
    Nokogiri::HTML(response.body)
  end

  let(:edit_params) do
    { title: 'Renamed',
      prominence: 'requester_only',
      described_state: 'waiting_response',
      awaiting_description: false,
      allow_new_responses_from: 'anybody',
      handle_rejected_responses: 'bounce' }
  end

  # The ids of the requests listed, in the order shown.
  def listed_request_ids
    page.css('#requests .item-detail').
      map { |row| row['id'].delete_prefix('request_').to_i }
  end

  def sort_option_labels
    page.css('.sort-options a').map { |link| link.text.strip }
  end

  # The SQL run while the block runs that reads any of the tables.
  def queries_on(*tables)
    sql = []
    record = ->(*, payload) { sql << payload[:sql] }
    ActiveSupport::Notifications.subscribed(record, 'sql.active_record') do
      yield
    end
    sql.grep(/FROM "(#{tables.join('|')})"/)
  end

  describe 'GET #index' do
    let(:info_request) { FactoryBot.create(:info_request) }

    before { sign_in(admin_user) }

    it "is successful" do
      get admin_requests_path
      expect(response).to be_successful
    end

    it 'lists all info requests' do
      info_request
      get admin_requests_path
      expect(listed_request_ids).to match_array(InfoRequest.pluck(:id))
      expect(listed_request_ids).to include(info_request.id)
    end

    it 'lists requests changed at the same moment newest first' do
      InfoRequest.update_all(updated_at: Time.zone.local(2026, 3, 1, 9))
      get admin_requests_path

      ids = listed_request_ids
      expect(ids.size).to be > 1
      expect(ids).to eq(ids.sort.reverse)
    end

    context 'when passed a query with the legacy search engine' do
      let!(:dog_request) do
        FactoryBot.create(:info_request, title: 'A dog request')
      end
      let!(:cat_request) do
        FactoryBot.create(:info_request, title: 'A cat request')
      end

      it 'lists info requests with titles matching the query
          case insensitively' do
        get admin_requests_path,
            params: { query: 'Cat', search_engine: 'legacy' }
        expect(listed_request_ids).not_to include(dog_request.id)
        expect(listed_request_ids).to include(cat_request.id)
      end

      it 'eager loads the associations the listing renders' do
        search = { query: 'cat', search_engine: 'legacy' }
        one_row = queries_on('users', 'public_bodies') do
          get admin_requests_path, params: search
        end
        expect(listed_request_ids).to eq([cat_request.id])
        expect(one_row.grep(/FROM "users"/)).not_to be_empty
        expect(one_row.grep(/FROM "public_bodies"/)).not_to be_empty

        2.times do |i|
          FactoryBot.create(:info_request, title: "Another cat request #{i}")
        end
        three_rows = queries_on('users', 'public_bodies') do
          get admin_requests_path, params: search
        end
        expect(listed_request_ids.size).to eq(3)

        expect(three_rows.size).to eq(one_row.size)
      end
    end

    context 'when passed a query with the new search engine', :postgresql do
      let!(:dog_request) do
        FactoryBot.create(:info_request, title: 'A dog request')
      end

      let!(:cat_request) do
        FactoryBot.create(:info_request, title: 'A cat request')
      end

      it 'lists info requests with titles matching the query' do
        get admin_requests_path, params: { query: 'Cat' }
        expect(listed_request_ids).to include(cat_request.id)
        expect(listed_request_ids).not_to include(dog_request.id)
      end

      it 'searches fields only admins can see' do
        hidden = FactoryBot.create(:info_request,
                                   prominence_reason: 'Names Winston Smith')
        get admin_requests_path, params: { query: 'Winston Smith' }
        expect(listed_request_ids).to include(hidden.id)
      end

      it 'lists all info requests when the query is blank' do
        get admin_requests_path, params: { query: '' }
        expect(listed_request_ids).to match_array(InfoRequest.pluck(:id))
      end

      it 'sorts by the chosen column rather than search relevance' do
        match = FactoryBot.create(:info_request,
                                  prominence_reason: 'A cat request')
        best_match = FactoryBot.create(
          :info_request,
          prominence_reason: 'A cat cat cat request'
        )
        best_match.update_columns(updated_at: 2.days.ago)

        get admin_requests_path,
            params: { query: 'cat', sort_order: 'updated_at_desc' }
        expect(listed_request_ids.first).to eq(match.id)
      end

      it 'offers relevance as a sort option' do
        get admin_requests_path, params: { query: 'cat' }
        expect(sort_option_labels.first).to eq('Relevance')
      end

      it 'does not offer relevance without a search' do
        get admin_requests_path
        expect(sort_option_labels).to include('Recently Updated')
        expect(sort_option_labels).not_to include('Relevance')
      end
    end
  end

  describe 'GET #show' do
    let(:info_request) { FactoryBot.create(:info_request) }

    before { sign_in(admin_user) }

    it "is successful" do
      get admin_request_path(info_request)
      expect(response).to be_successful
      expect(response.body).to include(info_request.title)
    end
  end

  describe 'GET #edit' do
    let(:info_request) { FactoryBot.create(:info_request) }

    before { sign_in(admin_user) }

    it "is successful" do
      get edit_admin_request_path(info_request)
      expect(response).to be_successful
      expect(page.at_css('h1').text).to eq('Edit basic details of request')
      expect(page.at_css('#info_request_title')['value']).
        to eq(info_request.title)
    end
  end

  describe 'PUT #update' do
    let(:info_request) { FactoryBot.create(:info_request) }

    before { sign_in(admin_user) }

    it "saves edits to a request" do
      put admin_request_path(info_request),
          params: { info_request: edit_params }
      expect(flash[:notice]).to include('successful')
      info_request.reload
      expect(info_request.title).to eq("Renamed")
    end

    it 'expires the request cache when saving edits to it' do
      allow(InfoRequest).to receive(:find).and_call_original
      allow(InfoRequest).to receive(:find).
        with(info_request.id).and_return(info_request)
      expect(info_request).to receive(:expire)
      put admin_request_path(info_request),
          params: { info_request: edit_params }
    end

    it 'redirects to request admin' do
      put admin_request_path(info_request),
          params: { info_request: edit_params }
      expect(response).to redirect_to admin_request_url(info_request)
    end
  end

  describe 'DELETE #destroy' do
    let(:info_request) { FactoryBot.create(:info_request) }

    before { sign_in(admin_user) }

    it 'destroys the info request' do
      delete admin_request_path(info_request)
      expect(InfoRequest).not_to exist(info_request.id)
      expect(flash[:notice]).
        to start_with("Request #{info_request.url_title} has been " \
                      'completely destroyed.')
    end

    it 'redirects after destroying a request with incoming_messages' do
      FactoryBot.create(:incoming_message, :with_html_attachment,
                        info_request: info_request)

      delete admin_request_path(info_request)

      expect(response).to redirect_to(admin_requests_url)
      expect(InfoRequest).not_to exist(info_request.id)
    end
  end

  describe 'POST #revert_report' do
    let(:info_request) { FactoryBot.create(:info_request) }
    let(:reporter) { FactoryBot.create(:user) }

    before do
      info_request.set_described_state('successful')
      info_request.report!('Vexatious', 'Please check', reporter)
    end

    let(:report_params) do
      { report_event_id: info_request.last_report_event.id }
    end

    let(:revert_path) { revert_report_admin_request_path(info_request) }

    context 'as an admin' do
      before { sign_in(admin_user) }

      it 'puts back the classification from before the report' do
        post revert_path, params: report_params
        expect(info_request.reload.described_state).to eq('successful')
      end

      it 'records the admin as the editor' do
        post revert_path, params: report_params
        expect(info_request.reload.last_event.params[:editor]).
          to eq(admin_user.url_name)
      end

      it 'says what it did and goes back to the request' do
        post revert_path, params: report_params
        expect(flash[:notice]).to eq('Request status reverted to successful.')
        expect(response).to redirect_to(admin_request_url(info_request))
      end

      it 'says why when it cannot, and changes nothing' do
        stale = report_params
        info_request.revert_report!(editor: admin_user.url_name,
                                    report_event_id: stale[:report_event_id])

        expect { post revert_path, params: stale }.
          not_to(change { info_request.info_request_events.count })
        expect(flash[:error]).to eq(
          'This request is not reported, so there is no report to revert.'
        )
        expect(response).to redirect_to(admin_request_url(info_request))
      end

      it 'refuses when the request was reported again since the page loaded' do
        stale = report_params.merge(
          report_event_id: info_request.last_report_event.id - 1
        )

        expect { post revert_path, params: stale }.
          not_to(change { info_request.info_request_events.count })
        expect(flash[:error]).to start_with(
          'The request has been reported again since the page was loaded.'
        )
      end

      it 'shows the error page when reverting fails in a way it does not ' \
         'expect', local_requests: false do
        allow(InfoRequest).to receive(:find).and_call_original
        allow(InfoRequest).to receive(:find).with(info_request.id).
          and_return(info_request)
        allow(info_request).to receive(:revert_report!).
          and_raise(ActiveRecord::StatementInvalid)

        post revert_path, params: report_params

        expect(response).to have_http_status(:internal_server_error)
        expect(page.at_css('#error-page')).to be_present
      end

      it 'checks the admin may administer this request' do
        get admin_request_path(info_request)
        expect(response).to have_http_status(:ok)

        allow_any_instance_of(Admin::RequestsController).
          to receive(:can?).and_call_original
        allow_any_instance_of(Admin::RequestsController).
          to receive(:can?).with(:admin, an_instance_of(InfoRequest)).
          and_return(false)

        post revert_path, params: report_params
        expect(response).to have_http_status(:not_found)
        expect(info_request.reload.described_state).
          to eq('attention_requested')
      end
    end

    it 'is not found for someone who is not an admin' do
      sign_in(reporter)
      get edit_users_name_path
      expect(response).to have_http_status(:ok)

      post revert_path, params: report_params
      expect(response).to have_http_status(:not_found)
      expect(info_request.reload.described_state).to eq('attention_requested')
    end
  end

  describe 'PATCH #prominence' do
    let(:info_request) { FactoryBot.create(:info_request) }

    it 'hides and restores a request inline and logs the edit event' do
      sign_in(admin_user)
      patch prominence_admin_request_path(info_request),
            params: { prominence: 'hidden', prominence_reason: 'Personal data' }
      expect(response).to redirect_to(admin_request_url(info_request))
      expect(info_request.reload.prominence).to eq('hidden')
      expect(info_request.prominence_reason).to eq('Personal data')
      expect(info_request.last_event.event_type).to eq('edit')

      patch prominence_admin_request_path(info_request),
            params: { prominence: 'requester_only' }
      expect(response).to redirect_to(admin_request_url(info_request))
      expect(info_request.reload.prominence).to eq('requester_only')
      expect(info_request.prominence_reason).to eq('')
    end

    it 'rejects unsupported prominence values' do
      sign_in(admin_user)
      patch prominence_admin_request_path(info_request),
            params: { prominence: 'normal' }
      expect(flash[:error]).to eq('Invalid visibility setting.')
      expect(info_request.reload.prominence).to eq('requester_only')
    end

    it 'ignores unsafe return_to values' do
      sign_in(admin_user)
      patch prominence_admin_request_path(info_request),
            params: { prominence: 'hidden', return_to: '/admin_evil' }
      expect(response).to redirect_to(admin_request_url(info_request))
    end

    it 'is not found for a non-admin user' do
      sign_in(info_request.user)
      patch prominence_admin_request_path(info_request),
            params: { prominence: 'hidden' }
      expect(response).to have_http_status(:not_found)
      expect(info_request.reload.prominence).to eq('requester_only')
    end
  end
end
