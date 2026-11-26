require 'spec_helper'

RSpec.describe 'Follow ups', type: :request do
  let(:request_user) { FactoryBot.create(:user) }
  let(:info_request) do
    FactoryBot.create(:info_request_with_incoming, user: request_user)
  end
  let(:message_id) { info_request.incoming_messages[0].id }
  let(:pro_user) { FactoryBot.create(:pro_user) }
  let(:page) { Nokogiri::HTML(response.body) }

  # Signs in and checks it worked, so that a refusal which follows is the
  # page's own and not a failed sign-in.
  def new_path(request, incoming_message_id = nil)
    if incoming_message_id
      new_request_incoming_followup_path(
        request_url_title: request.url_title,
        incoming_message_id: incoming_message_id
      )
    else
      new_request_followup_path(request_url_title: request.url_title)
    end
  end

  def preview_path(request)
    preview_request_followups_path(request_url_title: request.url_title)
  end

  def create_path(request)
    request_followups_path(request_url_title: request.url_title)
  end

  def followup_form
    page.at_css('form.followup-form')
  end

  def error_messages
    page.css('#errorExplanation li').map { _1.text.strip }
  end

  def expect_followup_form_for(request)
    expect(followup_form).to be_present
    expect(followup_form['action']).to start_with(create_path(request))
  end

  describe 'GET new' do
    context 'when not logged in' do
      it 'is not found for a private request' do
        private_request = FactoryBot.create(:info_request, :requester_only)
        get new_path(private_request)
        expect(response).to have_http_status(:not_found)
      end
    end

    context 'when a pro user is logged in' do
      before do
        sign_in! pro_user
      end

      it 'finds their own private requests' do
        private_request = FactoryBot.create(:info_request, :requester_only,
                                            user: pro_user)
        get new_path(private_request)
        expect(response).to have_http_status(:ok)
        expect_followup_form_for(private_request)
      end

      it 'is not found when not logged in as the request owner' do
        get new_path(info_request, message_id)
        expect(response).to have_http_status(:not_found)
      end

      it 'is not found for other private requests' do
        private_request = FactoryBot.create(:info_request, :requester_only)
        get new_path(private_request)
        expect(response).to have_http_status(:not_found)
      end
    end

    it 'is not found when not logged in as the request owner' do
      sign_in! FactoryBot.create(:user)
      get new_path(info_request, message_id)
      expect(response).to have_http_status(:not_found)
    end

    it 'is not found if not logged in' do
      get new_path(info_request)
      expect(response).to have_http_status(:not_found)
    end

    it 'does not ask a visitor to sign in to send a follow up' do
      post_redirects = PostRedirect.count
      get new_path(info_request, message_id)
      expect(response).to have_http_status(:not_found)
      expect(PostRedirect.count).to eq(post_redirects)
    end

    it 'does not ask a visitor to sign in to send a reply' do
      post_redirects = PostRedirect.count
      get new_path(info_request)
      expect(response).to have_http_status(:not_found)
      expect(PostRedirect.count).to eq(post_redirects)
    end

    context 'logged in as the request owner' do
      before do
        sign_in! request_user
      end

      it 'shows the followup form' do
        get new_path(info_request)
        expect(response).to have_http_status(:ok)
        expect_followup_form_for(info_request)
      end

      it 'shows the followup form when replying to an incoming message' do
        get new_path(info_request, message_id)
        expect(response).to have_http_status(:ok)
        expect_followup_form_for(info_request)
        expect(followup_form['action']).to include(message_id.to_s)
      end

      context 'the request has responses' do
        before do
          allow_any_instance_of(IncomingMessage).
            to receive(:valid_to_reply_to?).and_return(true)
          receive_incoming_mail('incoming-request-plain.eml',
                                to: info_request.incoming_email,
                                from: 'Frob <frob@bonce.com>')
        end

        it 'offers the opportunity to reply to the main address' do
          get new_path(info_request, message_id)
          link = page.at_css(
            "a[href='#{new_request_followup_path(info_request.url_title)}']"
          )
          expect(link.text).to eq('their main FOI address')
        end

        it 'offers an opportunity to reply to the officer who wrote' do
          get new_path(info_request, message_id)
          expect(page.at_css('p.followup-to').text).
            to include('To the officer who wrote.')
        end
      end

      context 'the request is hidden' do
        let(:hidden_request) do
          FactoryBot.create(:info_request_with_incoming, user: request_user,
                                                         prominence: 'hidden')
        end

        it 'does not show the form, even to the request owner' do
          get new_path(hidden_request)
          expect(response).to have_http_status(:not_found)
        end

        it 'responds to a json request with not found' do
          incoming_message_id = hidden_request.incoming_messages[0].id
          get new_request_incoming_followup_path(
            request_url_title: hidden_request.url_title,
            incoming_message_id: incoming_message_id,
            format: 'json'
          )
          expect(response).to have_http_status(:not_found)
        end
      end
    end

    context 'setting refusal advice' do
      before { sign_in info_request.user }

      it 'initialise without internal_review option' do
        expect(RefusalAdvice).to receive(:default).with(
          info_request, internal_review: false, user: info_request.user
        ).and_call_original

        get new_path(info_request)
      end

      it 'initialise with internal_review option' do
        expect(RefusalAdvice).to receive(:default).with(
          info_request, internal_review: true, user: info_request.user
        ).and_call_original

        get new_request_followup_path(
          request_url_title: info_request.url_title, internal_review: 1
        )
      end

      # The page draws nothing from the advice; this checks what the page
      # was given.
      it 'gives the page refusal advice' do
        given = []
        allow(RefusalAdvice).to(receive(:default).
          and_wrap_original { |original, *args, **opts|
            original.call(*args, **opts).tap { given << _1 }
          })
        get new_path(info_request)
        expect(response).to have_http_status(:ok)
        expect(given).to contain_exactly(an_instance_of(RefusalAdvice))
      end
    end
  end

  describe 'POST preview' do
    let(:dummy_message) do
      { body: 'What a useless response! You suck.',
        what_doing: 'normal_sort' }
    end

    context 'when not logged in' do
      it 'is not found for a private request' do
        private_request = FactoryBot.create(:info_request, :requester_only)
        post preview_path(private_request),
             params: { outgoing_message: dummy_message }
        expect(response).to have_http_status(:not_found)
      end

      it 'is not found' do
        post preview_path(info_request),
             params: { outgoing_message: dummy_message,
                       incoming_message_id: message_id }
        expect(response).to have_http_status(:not_found)
      end
    end

    context 'when a pro user is logged in' do
      before do
        sign_in! pro_user
      end

      it 'finds their own private requests' do
        private_request = FactoryBot.create(:info_request, :requester_only,
                                            user: pro_user)
        post preview_path(private_request),
             params: { outgoing_message: dummy_message }
        expect(response).to have_http_status(:ok)
        expect(page.at_css('form#preview_form')).to be_present
      end

      it 'is not found for other private requests' do
        private_request = FactoryBot.create(:info_request, :requester_only)
        post preview_path(private_request),
             params: { outgoing_message: dummy_message }
        expect(response).to have_http_status(:not_found)
      end
    end

    it 'is not found when not logged in as the request owner' do
      sign_in! FactoryBot.create(:user)
      post preview_path(info_request),
           params: { outgoing_message: dummy_message,
                     incoming_message_id: message_id }
      expect(response).to have_http_status(:not_found)
    end

    context 'logged in as the request owner' do
      before do
        sign_in request_user
      end

      it 'displays the edit form with an error when the body is blank' do
        post preview_path(info_request), params: {
          outgoing_message: { body: '', what_doing: 'normal_sort' },
          incoming_message_id: message_id
        }

        expect(response).to have_http_status(:unprocessable_content)
        expect_followup_form_for(info_request)
        expect(response.body).to include('Please enter your follow up message')
      end

      it 'shows a preview when input is good' do
        post preview_path(info_request), params: {
          outgoing_message: dummy_message,
          incoming_message_id: message_id,
          preview: 1
        }
        expect(response).to have_http_status(:ok)
        expect(page.at_css('form#preview_form')).to be_present
        expect(page.at_css('.correspondence_text').text).
          to include('What a useless response! You suck.')
        expect(followup_form).to be_nil
      end

      it 'allows re-editing of a preview' do
        post preview_path(info_request), params: {
          outgoing_message: dummy_message,
          incoming_message_id: message_id,
          reedit: 'Re-edit this request'
        }
        expect_followup_form_for(info_request)
        expect(page.at_css('form#preview_form')).to be_nil
      end
    end
  end

  describe 'POST create' do
    let(:dummy_message) do
      { body: 'What a useless response! You suck.',
        what_doing: 'normal_sort' }
    end

    def send_followup(request = info_request, incoming_id = message_id)
      post create_path(request), params: {
        outgoing_message: dummy_message,
        incoming_message_id: incoming_id
      }
    end

    shared_examples_for 'successful_followup_sent' do
      it 'sends the followup message' do
        send_followup

        deliveries = ActionMailer::Base.deliveries
        expect(deliveries.size).to eq(1)
        mail = deliveries[0]
        expect(mail.body).to match(/What a useless response! You suck./)
        expect(mail.to_addrs.first.to_s).
          to eq(info_request.public_body.request_email)
      end
    end

    context 'when not logged in' do
      it 'is not found for a private request' do
        private_request = FactoryBot.create(:info_request, :requester_only)
        post create_path(private_request),
             params: { outgoing_message: dummy_message }
        expect(response).to have_http_status(:not_found)
      end

      it 'is not found' do
        send_followup
        expect(response).to have_http_status(:not_found)
        expect(ActionMailer::Base.deliveries).to be_empty
      end
    end

    context 'when a pro user is logged in' do
      before do
        sign_in! pro_user
      end

      it 'finds their own private requests' do
        private_request = FactoryBot.create(:info_request, :requester_only,
                                            user: pro_user)
        expected_url = show_request_url(private_request.url_title)
        post create_path(private_request),
             params: { outgoing_message: dummy_message }
        expect(response).to redirect_to(expected_url)
      end

      it 'is not found for other private requests' do
        private_request = FactoryBot.create(:info_request, :requester_only)
        post create_path(private_request),
             params: { outgoing_message: dummy_message }
        expect(response).to have_http_status(:not_found)
      end
    end

    it 'only allows the request owner to make a followup' do
      sign_in! FactoryBot.create(:user)
      send_followup
      expect(response).to have_http_status(:not_found)
      expect(ActionMailer::Base.deliveries).to be_empty
    end

    context 'logged in as the request owner' do
      before do
        sign_in request_user
      end

      it "gives an error and shows the form again when a body isn't given" do
        post create_path(info_request), params: {
          outgoing_message: dummy_message.merge(body: ''),
          incoming_message_id: message_id
        }

        expect(response).to have_http_status(:unprocessable_content)
        expect(error_messages).to eq(['Please enter your follow up message'])
        expect_followup_form_for(info_request)
      end

      context 'a network error occurs while sending a followup' do
        def send_request
          send_followup
        end

        let(:outgoing_message) { info_request.reload.outgoing_messages.last }

        it_behaves_like 'NetworkSendErrors'
      end

      it_behaves_like 'successful_followup_sent'

      it 'updates the status for successful followup sends' do
        send_followup
        expect(info_request.reload.described_state).to eq('waiting_response')
      end

      context 'the request is no longer open to "anybody"' do
        before do
          info_request.update(
            allow_new_responses_from: 'authority_only',
            reject_incoming_at_mta: true
          )
        end

        it 'reopens the parent request to new responses' do
          send_followup
          expect(info_request.reload.allow_new_responses_from).
            to eq('anybody')
          expect(info_request.reload.reject_incoming_at_mta).to eq(false)
        end

        it_behaves_like 'successful_followup_sent'
      end

      it 'updates the event status if the request is waiting clarification' do
        info_request.set_described_state('waiting_clarification')

        send_followup

        expect(info_request.reload.last_public_response_event.
          calculated_state).to eq('waiting_clarification')
      end

      it 'redirects to the request page' do
        send_followup
        expect(response).
          to redirect_to(show_request_url(info_request.url_title))
      end

      it 'displays a confirmation once the message has been sent' do
        send_followup
        expect(flash[:notice]).
          to eq('Reply sent. If they asked you something, their 20 working ' \
                'days start again today.')
      end

      it 'displays an error if the request has been closed to new responses' do
        closed_request = FactoryBot.create(:info_request_with_incoming,
                                           user: request_user,
                                           allow_new_responses_from: 'nobody')

        send_followup(closed_request, closed_request.incoming_messages[0].id)
        deliveries = ActionMailer::Base.deliveries
        expect(deliveries.size).to eq(0)

        expect(response).to have_http_status(:unprocessable_content)
        expect(page.at_css('.followup-page')).to be_present

        expect(flash[:error][:partial]).to eq('followup_not_sent')

        expect(response.body).
          to include('Your follow up has not been sent because this ' \
                     'request has been stopped to prevent spam.')
      end

      context 'the same followup is submitted twice' do
        before do
          send_followup
          send_followup
        end

        it 'displays the form with an error message' do
          expect(response).to have_http_status(:unprocessable_content)
          expect_followup_form_for(info_request)
          expect(response.body).to include(
            'You previously submitted that exact follow up message for ' \
            'this request.'
          )
        end

        it 'only delivers the message once' do
          deliveries = ActionMailer::Base.deliveries
          expect(deliveries.size).to eq(1)
        end

        it 'does not repeat the message sent text' do
          expect(response.body).
            not_to include('Your follow up message has been sent on its way')
        end
      end
    end
  end
end
