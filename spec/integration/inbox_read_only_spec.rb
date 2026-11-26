require 'spec_helper'

RSpec.describe 'The inbox in read-only mode', type: :request do
  let(:user) { FactoryBot.create(:user) }
  let(:notice) { 'Alaveteli is currently in maintenance.' }

  before do
    allow(AlaveteliConfiguration).to receive(:read_only_features).
      and_return(%w[requests classifications])
    sign_in(user)
  end

  def expect_turned_away
    expect(response).to redirect_to(frontpage_url)
    follow_redirect!
    expect(response).to redirect_to(alaveteli_pro_dashboard_path)
    follow_redirect!
    expect(response).to have_http_status(:ok)
    expect(response.body).to include(notice)
  end

  it 'stops writing a request' do
    get '/pro/info_requests/new'
    expect_turned_away
  end

  it 'stops sending a request' do
    draft = FactoryBot.create(:draft_info_request, user: user)
    expect {
      post '/pro/info_requests', params: {
        draft_id: draft.id, review_token: RequestJourney::Review.token(draft)
      }
    }.not_to change(InfoRequest, :count)
    expect_turned_away
  end

  it 'stops writing and sending a batch' do
    get '/pro/info_request_batches/new', params: { draft_id: 1 }
    expect_turned_away

    expect {
      post '/pro/info_request_batches', params: { draft_id: 1 }
    }.not_to change(InfoRequestBatch, :count)
    expect_turned_away
  end

  it 'stops saving a draft' do
    expect {
      post '/pro/info_requests', params: {
        info_request: { title: 'Grit bin sites' },
        outgoing_message: { body: 'Where are the grit bins?' },
        save_draft: 1
      }
    }.not_to change(DraftInfoRequest, :count)
    expect_turned_away

    expect {
      post '/pro/draft_info_request_batches', params: {
        alaveteli_pro_draft_info_request_batch: { title: 'Grit bin sites' }
      }
    }.not_to change(AlaveteliPro::DraftInfoRequestBatch, :count)
    expect_turned_away
  end

  it 'stops deleting a draft' do
    draft = FactoryBot.create(:draft_info_request, user: user,
                                                   title: 'Grit bin sites')
    delete "/pro/draft_info_requests/#{draft.id}"
    expect(DraftInfoRequest.exists?(draft.id)).to be(true)
    expect_turned_away
  end

  it 'stops answering a reply' do
    info_request = FactoryBot.create(:info_request_with_incoming, user: user)
    post "/pro/info_requests/#{info_request.url_title}/classifications",
         params: {
           classification: { described_state: 'successful' },
           last_info_request_event_id:
             info_request.last_event_id_needing_description
         }
    expect(info_request.reload.described_state).not_to eq('successful')
    expect_turned_away
  end

  it 'keeps the inbox open' do
    get '/pro/dashboard'
    expect(response).to have_http_status(:ok)
  end
end
