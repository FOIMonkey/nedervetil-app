require 'spec_helper'

# What a controller answers when a page needs a signed-in account, or a
# particular one: the wrong-account page, or the way to the sign-in page and
# back.
RSpec.describe 'Asking a visitor to sign in', type: :request do
  let(:owner) { FactoryBot.create(:user, name: 'Rowan Requester') }
  let(:admin) { FactoryBot.create(:admin_user) }
  let(:info_request) { FactoryBot.create(:info_request, user: owner) }

  describe 'someone signed in as another account' do
    before { sign_in(admin) }

    it 'is told whose page it is' do
      get new_request_followup_path(request_url_title: info_request.url_title)

      expect(response).to have_http_status(:ok)
      expect(response.body).
        to include('Sorry, but only Rowan Requester can do that.')
    end

    it 'gets that page with a 422 when it was a form' do
      post request_followups_path(request_url_title: info_request.url_title),
           params: { outgoing_message: { body: 'A follow up' } }

      expect(response).to have_http_status(422)
      expect(response.body).
        to include('Sorry, but only Rowan Requester can do that.')
    end
  end

  describe 'a visitor who wrote a letter signed out' do
    let(:authority) { FactoryBot.create(:public_body) }

    it 'is told it is saved as a draft, once signed in' do
      post new_request_path, params: {
        submitted_new_request: 1,
        info_request: { title: 'Depot opening hours',
                        public_body_id: authority.id },
        outgoing_message: { body: "Dear Authority,\nPlease send the depot " \
                                  "opening hours.\nYours faithfully,\n" \
                                  'Rowan Requester' }
      }
      expect(response).to redirect_to(signup_path)

      sign_in(owner)
      follow_redirect!

      expect(response.body).
        to include('Your request is saved as a draft. Review it before ' \
                   'sending.')
    end
  end

  describe 'a signed-out visitor' do
    it 'is not told that a page for one account exists' do
      get new_request_followup_path(request_url_title: info_request.url_title)

      expect(response).to have_http_status(:not_found)
    end

    it 'is sent to sign in, and back to the inbox page asked for' do
      get '/pro/dashboard'

      expect(response).to redirect_to(signin_path(r: '/pro/dashboard'))
      expect(response.headers['Cache-Control']).to eq('private, no-store')
    end

    it 'is given no way back when the page is the inbox itself' do
      get '/pro/info_requests'

      expect(response).to redirect_to(signin_path)
    end

    it 'comes back to the same page of a list' do
      get '/pro/info_requests', params: { page: '2', other: 'x' }

      expect(response).
        to redirect_to(signin_path(r: '/pro/info_requests?page=2'))
    end

    it 'comes back to a draft by its id alone' do
      get '/pro/info_requests/new', params: { draft_id: '7', other: 'x' }

      expect(response).
        to redirect_to(signin_path(r: '/pro/info_requests/new?draft_id=7'))
    end

    it 'keeps the sign-in dialog' do
      get '/pro/dashboard', params: { modal: '1' }

      expect(response).
        to redirect_to(signin_path(r: '/pro/dashboard', modal: 1))
    end

    it 'comes back to a page outside the inbox, whatever draft_id says' do
      get '/profile/ai_reading', params: { draft_id: '7' }

      expect(response).to redirect_to(signin_path(r: '/profile/ai_reading'))
    end
  end
end
