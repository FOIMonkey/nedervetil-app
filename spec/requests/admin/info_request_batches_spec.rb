require 'spec_helper'

RSpec.describe 'Admin info request batches', type: :request do
  before { sign_in FactoryBot.create(:admin_user) }

  let(:page) { Nokogiri::HTML(response.body) }

  # Read from the latest response, as page is memoised.
  def listed_request_ids
    Nokogiri::HTML(response.body).css('#requests .item-detail[id^="request_"]').
      map { |row| row['id'].delete_prefix('request_').to_i }
  end

  describe 'GET show' do
    context 'when the user can admin the batch' do
      let(:batch) { FactoryBot.create(:info_request_batch) }

      before { get admin_info_request_batch_path(batch) }

      it 'shows the batch and its requests' do
        expect(response).to have_http_status(:ok)
        expect(page.at_css('h1').text).
          to include("Batch FOI request – #{batch.title}")
        expect(listed_request_ids).to be_empty
        expect(page.at_css('#requests').text).to include('None yet.')
      end
    end

    context 'when paginating' do
      let(:batch) do
        FactoryBot.create(:info_request_batch, :sent, public_body_count: 1)
      end

      # 101 requests, copied with their events from the batch's one: made
      # one by one they take seconds.
      before do
        request = batch.info_requests.first
        copy = request.attributes.except('id')
        ids = InfoRequest.insert_all(
          Array.new(100) do |i|
            copy.merge('url_title' => "#{request.url_title}_#{i}")
          end,
          returning: :id
        ).rows.flatten
        events = request.info_request_events.map do |event|
          event.attributes.except('id')
        end
        InfoRequestEvent.insert_all(
          ids.product(events).map do |id, event|
            event.merge('info_request_id' => id)
          end
        )
      end

      it 'shows the requests 100 to a page' do
        get admin_info_request_batch_path(batch)
        first_page = listed_request_ids
        expect(first_page.size).to eq(100)

        get admin_info_request_batch_path(batch, page: 2)
        expect(response).to have_http_status(:ok)
        second_page = listed_request_ids
        expect(second_page.size).to eq(1)
        expect(first_page + second_page).
          to match_array(batch.info_requests.reload.ids)
      end

      it 'shows an empty page past the last' do
        get admin_info_request_batch_path(batch, page: 3)
        expect(response).to have_http_status(:ok)
        expect(listed_request_ids).to be_empty
        expect(page.at_css('#requests').text).to include('None yet.')
      end
    end

    context 'when the user cannot admin the batch' do
      let(:batch) { FactoryBot.create(:info_request_batch) }
      let(:ability) { Object.new.extend(CanCan::Ability) }

      it 'returns a 404' do
        get admin_info_request_batch_path(batch)
        expect(response).to have_http_status(:ok)

        ability.can :access, :admin
        ability.cannot :admin, batch
        allow_any_instance_of(Admin::InfoRequestBatchesController).
          to receive(:current_ability).and_return(ability)
        get admin_info_request_batch_path(batch)
        expect(response).to have_http_status(:not_found)
      end
    end
  end
end
