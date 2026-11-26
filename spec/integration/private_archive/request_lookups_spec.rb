require 'spec_helper'

# Pages that look a request up by its URL title or by one of its events,
# without a read check of their own: the privacy gate (PrivateArchive) checks
# the request first. These looked requests up with InfoRequest.not_embargoed
# until embargoes were removed (see doc/FORK.md).
RSpec.describe 'Pages that name a private request' do
  include_context 'with production error pages'

  let(:owner) { FactoryBot.create(:user) }
  let(:stranger) { FactoryBot.create(:user) }
  let(:info_request) do
    FactoryBot.create(:info_request, user: owner,
                                     title: 'Lookuptoken private request')
  end
  let(:event) { info_request.info_request_events.first }

  def urls
    ["/help/unhappy/#{info_request.url_title}",
     "/request/#{info_request.url_title}/report/new",
     "/request_event/#{event.id}"]
  end

  it 'is a private request, owned by someone else' do
    expect(info_request.prominence).to eq('requester_only')
    expect(event.event_type).to eq('sent')
  end

  it 'gives a 404 to someone else, revealing neither title nor address' do
    { 'a visitor' => nil, 'another user' => stranger }.each do |name, viewer|
      urls.each do |url|
        viewer ? sign_in(viewer) : reset!
        get url
        expect(response).to have_http_status(:not_found), "#{url} as #{name}"
        expect(response.body).not_to include('Lookuptoken')
        expect(response.headers['Location']).to be_nil
      end
    end
  end

  it 'still serves them to the requester' do
    sign_in(owner)
    get urls.first
    expect(response).to be_successful
    get urls.last
    expect(response).to have_http_status(:moved_permanently)
    expect(response.location).
      to start_with("http://www.example.com/request/#{info_request.url_title}#")
  end
end
