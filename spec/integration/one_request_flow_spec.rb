require 'spec_helper'

RSpec.describe 'Signed-in request flow', type: :request do
  let(:user) { FactoryBot.create(:user) }
  let(:body) { FactoryBot.create(:public_body) }

  def page_html
    Nokogiri::HTML(response.body)
  end

  def inbox_link
    page_html.at_css('#topnav a[href="/pro/dashboard"]')
  end

  def home_crumb
    page_html.at_css('.request-band__crumb a[href="/pro/dashboard"]')
  end

  shared_examples 'every signed-in account' do
    it 'sends the home page to the inbox' do
      get '/'
      expect(response).to redirect_to(alaveteli_pro_dashboard_path)
    end

    it 'opens the inbox' do
      get '/pro/dashboard'
      expect(response).to have_http_status(:ok)
      expect(page_html.at_css('.dashboard-page')).to be_present
    end

    it 'sends the classic request form to the inbox form' do
      get '/new'
      expect(response).to redirect_to(new_alaveteli_pro_info_request_url)

      get "/new/#{body.url_name}"
      expect(response).to redirect_to(
        new_alaveteli_pro_info_request_url(public_body: body.url_name)
      )
    end

    it 'links to the inbox from the navigation' do
      get '/help/about'
      expect(inbox_link).to be_present
    end

    it 'opens its unsent batch in the inbox' do
      batch = FactoryBot.create(:info_request_batch, user: user)
      get "/info_request_batch/#{batch.id}"
      expect(response).
        to redirect_to(show_alaveteli_pro_batch_request_url(batch))
    end

    it 'shows its own request with a Home link to the inbox' do
      info_request = FactoryBot.create(:info_request, user: user)
      get "/request/#{info_request.url_title}"
      expect(response).to have_http_status(:ok)
      expect(home_crumb).to be_present
    end
  end

  context 'with the alaveteli_pro flag on', feature: :alaveteli_pro do
    before { sign_in(user) }

    include_examples 'every signed-in account'
  end

  context 'with the flag off' do
    before { sign_in(user) }

    include_examples 'every signed-in account'
  end

  it 'keeps a sign-in notice through the home page to the inbox' do
    allow(AlaveteliConfiguration).
      to receive(:enable_two_factor_auth).and_return(true)
    totp_user = FactoryBot.create(:user, :enable_totp)
    codes = totp_user.generate_otp_backup_codes!
    totp_user.save!
    post '/profile/sign_in', params: {
      user_signin: { email: totp_user.email, password: 'jonespassword',
                     otp_attempt: codes.first }
    }
    follow_redirect! while response.redirect?
    expect(path).to eq(alaveteli_pro_info_requests_path)
    expect(response.body).to include('You used a backup code')
  end

  context 'when starting signed out' do
    it 'shows the classic form' do
      get "/new/#{body.url_name}"
      expect(response).to have_http_status(:ok)
      expect(page_html.at_css('form#write_form')).to be_present
    end

    it 'turns the request into an inbox draft at sign-in' do
      post '/new', params: {
        info_request: { public_body_id: body.id, title: 'Grit bin sites',
                        tag_string: '' },
        outgoing_message: { body: 'Where are the grit bins?' },
        submitted_new_request: 1, preview: 0
      }
      post '/profile/sign_in', params: {
        user_signin: { email: user.email, password: 'jonespassword' }
      }
      draft = user.draft_info_requests.last
      expect(draft.title).to eq('Grit bin sites')
      expect(response.location).
        to include(new_alaveteli_pro_info_request_path(draft_id: draft.id))
    end
  end
end
