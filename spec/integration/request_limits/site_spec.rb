require 'spec_helper'

RSpec.describe 'Request limits on the site', feature: :alaveteli_pro do
  include_context 'with request limits on, on the real clock'
  include_context 'with incoming attention off' if defined?(IncomingAttention::Config)

  before do
    allow(Rails.application.config).
      to receive(:consider_all_requests_local).and_return(false)
  end

  let(:owner) { FactoryBot.create(:user) }
  let(:authority) { FactoryBot.create(:public_body) }

  def draft(title)
    post '/pro/info_requests', params: {
      info_request: { title: title, public_body_id: authority.id },
      outgoing_message: { body: RequestLetter.join("Please provide #{title}.",
                                                   authority.name,
                                                   owner.name) },
      review: 1
    }
    owner.draft_info_requests.last
  end

  it 'refuses a second request within the minute, keeping the draft and sending nothing' do
    sign_in(owner)
    first = draft('Gritting routes 2025')
    post '/pro/info_requests', params: { draft_id: first.id, review_token: RequestJourney::Review.token(first) }
    expect(response).to be_redirect
    second = draft('Bin rounds 2025')
    deliveries = ActionMailer::Base.deliveries.size
    post '/pro/info_requests', params: { draft_id: second.id, review_token: RequestJourney::Review.token(second) }
    expect(response).to have_http_status(:too_many_requests)
    expect(response.body).
      to include('You’ve sent a request in the last minute.',
                 'Your draft is saved.')
    page = Nokogiri::HTML(response.body)
    expect(page.css('h1').map(&:text)).to include('Sending limit reached')
    expect(Time.iso8601(page.at_css('time')['datetime'])).to be > Time.current
    expect(page.at_css('a[href*="filter%5D=draft"]').text).to eq('your drafts')
    expect(page.css('h2').map(&:text)).
      to include('Why there are limits', 'If you need to send more')
    expect(page.at_css("a[href='#{help_contact_path}']").text).
      to eq('Contact us about your limit')
    expect(ActionMailer::Base.deliveries.size).to eq(deliveries)
    expect(owner.info_requests.count).to eq(1)
    expect(owner.draft_info_requests).to include(second)
  end

  it 'refuses a fourth follow-up on one request within five minutes, showing the message' do
    request = without_limits {
      FactoryBot.create(:info_request_with_incoming, user: owner)
    }
    incoming = request.incoming_messages.last
    sign_in(owner)
    send_followup = ->(text) do
      post "/request/#{request.url_title}/followups", params: {
        outgoing_message: { body: text, what_doing: 'normal_sort' },
        incoming_message_id: incoming.id
      }
    end
    3.times { |n| send_followup.call("Follow-up number #{n}") }
    send_followup.call('One message too many')
    expect(response).to have_http_status(:too_many_requests)
    expect(response.body).
      to include('You’ve sent 3 messages on this request in the last 5 ' \
                 'minutes.')
    box = Nokogiri::HTML(response.body).at_css('textarea[readonly]')
    expect(box.text).to eq('One message too many')
    expect(
      Nokogiri::HTML(response.body).at_css("label[for='#{box['id']}']").text
    ).to eq('Message text')
    expect(request.outgoing_messages.where(message_type: 'followup').count).
      to eq(3)
  end

  it 'hides every batch page unless the account is trusted' do
    sign_in(owner)
    get alaveteli_pro_batch_request_authority_searches_path
    expect(response).to have_http_status(:not_found)
    expect {
      post '/pro/draft_info_request_batches',
           params: { alaveteli_pro_draft_info_request_batch: {
             title: 'Batch', body: 'Please.', public_body_ids: authority.id
           } }
    }.not_to change(AlaveteliPro::DraftInfoRequestBatch, :count)
    expect(response).to have_http_status(:not_found)

    owner.update!(trusted: true)
    get alaveteli_pro_batch_request_authority_searches_path
    expect(response).to have_http_status(:ok)
  end
end
