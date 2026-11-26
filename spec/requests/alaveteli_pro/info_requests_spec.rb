require 'spec_helper'

RSpec.describe 'Pro requests', type: :request do
  let(:pro_user) { FactoryBot.create(:pro_user) }
  let(:page) { Nokogiri::HTML(response.body) }

  def heading
    page.at_css('h1.page-band__title').text
  end

  def error_messages
    page.css('#errorExplanation li').map { _1.text.strip }
  end

  def expect_each_error_once_without_the_request_copy
    expect(error_messages).to eq(
      ['Please enter your letter requesting information',
       'Please sign at the bottom with your name, or alter the ' \
       '"Yours faithfully," signature']
    )
  end

  def review_params(draft)
    { draft_id: draft.id, review_token: RequestJourney::Review.token(draft) }
  end

  describe 'GET index' do
    let!(:info_request) do
      FactoryBot.create(:info_request, user: pro_user, title: 'Grit bins')
    end

    let!(:foo_request) do
      FactoryBot.create(:info_request, user: pro_user, title: 'Foo foo')
    end

    before do
      FactoryBot.create(:info_request, title: 'Someone else request')
      sign_in pro_user
    end

    it 'shows the requests page with its search' do
      get alaveteli_pro_info_requests_path
      expect(response).to have_http_status(:ok)
      expect(heading).to eq('Requests')
      search = 'form input[name="alaveteli_pro_request_filter[search]"]'
      expect(page.at_css(search)).to be_present
    end

    context 'when no filters, searches or sort params are passed' do
      it "lists the user's requests, and only theirs" do
        get alaveteli_pro_info_requests_path
        expect(response.body).to include('Grit bins', 'Foo foo')
        expect(response.body).not_to include('Someone else request')
      end
    end

    context 'when a filter is passed' do
      def listed
        page.css('.requests__list .request__title a').map { _1.text.strip }
      end

      it "lists the user's request summaries in that filter" do
        get alaveteli_pro_info_requests_path(
          alaveteli_pro_request_filter: { filter: 'awaiting_response' }
        )
        expect(listed).to match_array(['Grit bins', 'Foo foo'])
      end

      it 'applies a search to them' do
        get alaveteli_pro_info_requests_path(
          alaveteli_pro_request_filter: { filter: 'awaiting_response',
                                          search: 'foo' }
        )
        expect(listed).to eq(['Foo foo'])
        expect(page.at_css('.search-and-filter-overview').text).
          to include('Searching for foo')
      end
    end

    context 'when a search is passed' do
      it 'applies the search' do
        get alaveteli_pro_info_requests_path(
          alaveteli_pro_request_filter: { search: 'foo' }
        )
        expect(response.body).to include('Foo foo')
        expect(response.body).not_to include('Grit bins')
      end
    end
  end

  describe 'GET new' do
    context 'if the current_user is banned' do
      before do
        pro_user.update!(ban_text: 'banned')
        sign_in pro_user
      end

      it 'shows the banned page' do
        get new_alaveteli_pro_info_request_path
        expect(heading).to eq('Banned from this site')
      end
    end
  end

  describe 'GET preview' do
    let(:draft) do
      FactoryBot.create(:draft_info_request, body: nil, user: pro_user)
    end

    before { sign_in pro_user }

    context 'when there are errors on the outgoing message' do
      it 'shows each error once, not the copy on the request' do
        get preview_new_alaveteli_pro_info_request_path(draft_id: draft.id)
        expect(response).to have_http_status(:unprocessable_content)
        expect_each_error_once_without_the_request_copy
      end
    end

    context 'when the public body is not requestable' do
      let(:public_body) { FactoryBot.create(:public_body, :defunct) }
      let(:draft) do
        FactoryBot.create(:draft_info_request, public_body: public_body,
                                               user: pro_user)
      end

      it 'tells the user' do
        get preview_new_alaveteli_pro_info_request_path(draft_id: draft.id)
        expect(heading).to eq("'#{public_body.name}' is defunct")
      end
    end

    context 'without draft' do
      it 'redirects to new info request action' do
        get preview_new_alaveteli_pro_info_request_path
        expect(response).to redirect_to(new_alaveteli_pro_info_request_url)
      end
    end

    context 'if the current_user is banned' do
      before { pro_user.update!(ban_text: 'banned') }

      it 'shows the banned page' do
        get preview_new_alaveteli_pro_info_request_path(draft_id: draft.id)
        expect(heading).to eq('Banned from this site')
      end
    end
  end

  describe 'POST create' do
    let(:draft) do
      FactoryBot.create(:draft_info_request, body: nil, user: pro_user)
    end

    context 'when there are errors on the outgoing message' do
      it 'shows each error once, not the copy on the request' do
        sign_in pro_user
        post alaveteli_pro_info_requests_path, params: review_params(draft)
        expect(response).to have_http_status(:unprocessable_content)
        expect(heading).to eq('Write request')
        expect_each_error_once_without_the_request_copy
      end
    end

    context 'without draft' do
      it 'redirects to new info request action' do
        sign_in pro_user
        post alaveteli_pro_info_requests_path
        expect(response).to redirect_to(new_alaveteli_pro_info_request_url)
      end
    end

    context 'if the current_user is banned' do
      before do
        pro_user.update!(ban_text: 'banned')
        sign_in pro_user
      end

      it 'shows the banned page' do
        expect {
          post alaveteli_pro_info_requests_path,
               params: { draft_id: draft.id }
        }.not_to change(InfoRequest, :count)
        expect(response).to have_http_status(:unprocessable_content)
        expect(heading).to eq('Banned from this site')
      end
    end

    context 'a network error occurs while sending the request' do
      let(:user) { FactoryBot.create(:user) }
      let(:info_request) { user.info_requests.last }
      let(:outgoing_message) { info_request.reload.outgoing_messages.last }

      before { sign_in user }

      def send_request
        draft = FactoryBot.create(:draft_info_request, user: user)
        post alaveteli_pro_info_requests_path, params: review_params(draft)
      end

      it_behaves_like 'NetworkSendErrors'

      it 'says the request was saved but not sent, not that it was sent' do
        allow_any_instance_of(ActionMailer::MessageDelivery).
          to receive(:deliver_now).and_raise(Errno::ETIMEDOUT)
        send_request
        expect(response).
          to redirect_to(show_request_path(url_title: info_request.url_title))
        expect(flash[:request_sent]).to be_nil
        expect(flash[:error]).to eq(
          'An error occurred while sending your request to ' \
          "#{info_request.public_body.name} but has been saved and flagged " \
          'for administrator attention.'
        )
      end

      it 'says it was sent when it was' do
        send_request
        expect(flash[:request_sent]).to eq(true)
        expect(flash[:error]).to be_nil
      end
    end

    describe 'a repeat of a request' do
      let(:user) { FactoryBot.create(:user) }
      let(:authority) { FactoryBot.create(:public_body) }
      let(:repeat_message) { 'You already made the same request on' }

      def send_letter(as:)
        draft = FactoryBot.create(:draft_info_request,
                                  user: as, public_body: authority,
                                  title: 'Grit bin sites',
                                  body: 'Where are the grit bins?')
        post alaveteli_pro_info_requests_path, params: review_params(draft)
      end

      def switch_to(user)
        reset!
        sign_in user
      end

      it 'refuses the same letter to the same authority from the same ' \
         'requester' do
        sign_in user
        send_letter(as: user)
        expect { send_letter(as: user) }.not_to change(InfoRequest, :count)
        expect(response).to have_http_status(422)
        expect(error_messages.first).to start_with(repeat_message)
      end

      it 'refuses it after a failed send too, which waits for an admin' do
        sign_in user
        allow_any_instance_of(ActionMailer::MessageDelivery).
          to receive(:deliver_now).and_raise(Errno::ETIMEDOUT)
        send_letter(as: user)
        expect(flash[:error]).to include('flagged for administrator attention')

        expect { send_letter(as: user) }.not_to change(InfoRequest, :count)
        expect(error_messages.first).to start_with(repeat_message)
      end

      it "doesn't look at, or name, someone else's identical request" do
        other = FactoryBot.create(:user, name: 'Another Requester')
        sign_in other
        send_letter(as: other)
        switch_to(user)
        expect { send_letter(as: user) }.to change(InfoRequest, :count).by(1)
        expect(response).to be_redirect
        expect(flash.to_h.values.join).not_to include('Another Requester')
      end
    end

    describe 'checks before sending' do
      let(:user) { FactoryBot.create(:user, confirmed_not_spam: false) }
      let(:spam_title) { '[HD] Watch Jason Bourne Online free MOVIE Full-HD' }
      let(:unable) do
        "Sorry, we're currently unable to send your request. " \
          'Please try again later.'
      end

      before { sign_in user }

      def send_draft(title)
        draft = FactoryBot.create(:draft_info_request, user: user,
                                                       title: title)
        post alaveteli_pro_info_requests_path, params: review_params(draft)
        draft
      end

      def admin_notices
        ActionMailer::Base.deliveries.map(&:subject).grep(/Spam|spam/)
      end

      def expect_refused(draft, message)
        expect(response).to have_http_status(422)
        expect(heading).to eq('Check and send')
        expect(flash[:error]).to eq(message)
        expect(user.info_requests.reload).to be_empty
        expect(DraftInfoRequest.exists?(draft.id)).to eq(true)
      end

      def expect_sent(title)
        sent = user.info_requests.reload.find_by(title: title)
        expect(sent).to be_present
        expect(response).
          to redirect_to(show_request_path(url_title: sent.url_title))
      end

      context 'when the subject looks like spam' do
        it 'refuses and tells the admins when spam requests are blocked' do
          allow(AlaveteliConfiguration).
            to receive(:block_spam_requests).and_return(true)
          draft = send_draft(spam_title)
          expect_refused(draft, unable)
          expect(admin_notices.first).
            to match(/Spam request from user #{user.id}/)
        end

        it 'sends and tells the admins when spam requests are not blocked' do
          allow(AlaveteliConfiguration).
            to receive(:block_spam_requests).and_return(false)
          send_draft(spam_title)
          expect_sent(spam_title)
          expect(admin_notices.first).
            to match(/Spam request from user #{user.id}/)
        end

        it 'reads Cyrillic look-alike letters as Latin ones' do
          allow(AlaveteliConfiguration).
            to receive(:block_spam_requests).and_return(true)
          # A Cyrillic о and Р in place of the Latin letters.
          draft = send_draft('Watch the Mоvie Online with Рutlocker')
          expect_refused(draft, unable)
        end

        it 'reads Greek look-alike letters as Latin ones' do
          allow(AlaveteliConfiguration).
            to receive(:block_spam_requests).and_return(true)
          # A Greek τ in place of the Latin t.
          draft = send_draft('Puτlocker links')
          expect_refused(draft, unable)
          expect(admin_notices.first).
            to match(/Spam request from user #{user.id}/)
        end
      end

      context 'when an admin has confirmed the account is not spam' do
        before do
          user.update!(confirmed_not_spam: true)
          allow(AlaveteliConfiguration).
            to receive(:block_spam_requests).and_return(true)
          allow(Turnstile).to receive(:check).and_return(:failed)
        end

        it 'sends without any of the checks' do
          send_draft(spam_title)
          expect_sent(spam_title)
          expect(admin_notices).to be_empty
        end
      end
    end
  end

  describe 'the person check on the send form' do
    let(:user) { FactoryBot.create(:user, confirmed_not_spam: false) }
    let(:draft) { FactoryBot.create(:draft_info_request, user: user) }

    before do
      sign_in user
      allow(Turnstile).to receive_messages(configured?: true,
                                           site_key: 'site-key')
    end

    it 'is shown to a new account, named as the check names it' do
      get preview_new_alaveteli_pro_info_request_path(draft_id: draft.id)
      expect(response.body).
        to include('cf-turnstile', 'site-key', 'data-action="first_request"')
    end

    it 'carries a nonce on its script, for the page policy' do
      get preview_new_alaveteli_pro_info_request_path(draft_id: draft.id)
      script = page.at_css("script[src='#{Turnstile::SCRIPT_URL}']")
      expect(script['nonce']).to be_present
    end

    it 'is not shown to an account that has made a request before' do
      FactoryBot.create(:info_request, user: user)
      get preview_new_alaveteli_pro_info_request_path(draft_id: draft.id)
      expect(response).to have_http_status(:ok)
      expect(response.body).not_to include('cf-turnstile')
    end
  end
end
