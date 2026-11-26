require 'spec_helper'

# With enforcement off the send log doesn't stop anyone, and a suspended
# account is still refused. Every signed-in account writes in the inbox form
# (#93), with Pro on or off.
RSpec.describe 'Requests with disabled enforcement',
               features: { alaveteli_pro: false } do
  include_context 'with request limits off'

  let(:user) { FactoryBot.create(:user) }
  let(:authority) { FactoryBot.create(:public_body) }
  let(:draft) do
    FactoryBot.create(:draft_info_request, user: user, public_body: authority,
                                           title: 'Gritting routes',
                                           body: 'Please provide the ' \
                                                 'gritting routes.')
  end

  def send_draft
    post '/pro/info_requests', params: {
      draft_id: draft.id, review_token: RequestJourney::Review.token(draft)
    }
  end

  before do
    sign_in(user)
  end

  it 'opens the form for a non-exempt account' do
    get '/pro/info_requests/new', params: { public_body: authority.url_name }

    expect(response).to have_http_status(:ok)
    expect(response.body).to include('id="subject_form"')
  end

  it 'creates and sends a request even when the send log exceeds the cap' do
    3.times { RequestLimits::Send.create!(user_id: user.id, kind: 'request') }

    expect { send_draft }.
      to change { user.info_requests.count }.by(1).
      and change(OutgoingMessage, :count).by(1).
      and change { ActionMailer::Base.deliveries.size }.by(1)

    expect(response).
      to redirect_to(show_request_path(user.info_requests.last.url_title))
  end

  context 'with a suspended account' do
    before { user.update!(ban_text: 'Suspended') }

    it 'shows the suspension page instead of opening the form' do
      get '/pro/info_requests/new', params: { public_body: authority.url_name }

      expect(response.body).to include('Banned from this site')
    end

    it 'refuses submission without creating a request or sending mail' do
      draft
      expect { send_draft }.not_to(change {
        [InfoRequest.count, OutgoingMessage.count,
         ActionMailer::Base.deliveries.size]
      })

      expect(response.body).to include('Banned from this site')
    end
  end
end
