require 'spec_helper'

RSpec.describe 'Inbox request classifications', type: :request do
  describe 'POST create' do
    let(:user) { FactoryBot.create(:pro_user) }
    let(:info_request) { FactoryBot.create(:info_request, user: user) }

    def post_status(status, message: nil)
      classification = { described_state: status }
      classification[:message] = message if message

      path = alaveteli_pro_classifications_path(
        url_title: info_request.url_title
      )
      post path, params: { classification: classification }
    end

    context 'when the request to be classified can not be found' do
      it 'answers not found' do
        sign_in user
        expect_signed_in_as(user)
        post alaveteli_pro_classifications_path(url_title: 'invalid')
        expect(response).to have_http_status(:not_found)
      end
    end

    context 'when the user is not allowed to update the request',
            local_requests: false do
      # A suspended requester still sees their request, but may not act on it.
      let(:user) { FactoryBot.create(:user, :banned) }

      it 'refuses the classification with a 403 page' do
        sign_in! user
        post_status('successful')
        expect(response).to have_http_status(:forbidden)
        expect(response.body).to include('id="error-page"')
        expect(info_request.reload.described_state).to eq('waiting_response')
      end
    end

    shared_examples 'classify request as successful' do
      before { sign_in user }

      it 'should create status_update log' do
        post_status('successful')

        event = InfoRequestEvent.last
        expect(event.event_type).to eq 'status_update'
        expect(event.params[:described_state]).to eq 'successful'
        expect(event.params[:old_described_state]).to eq 'waiting_response'
        expect(event.params[:user]).to eq(user)
      end

      it 'should set the described state of the request' do
        post_status('successful')
        expect(info_request.reload.described_state).to eq('successful')
      end

      it 'should redirect back to the request' do
        post_status('successful')
        expect(response).to redirect_to(
          show_request_path(url_title: info_request.url_title,
                            anchor: 'receipt-answer')
        )
      end
    end

    context 'when the user is allowed to update the request' do
      include_examples 'classify request as successful'
    end

    # The reply's question says which reply it answers.
    context 'when the form says which reply it answers' do
      let(:info_request) do
        FactoryBot.create(:info_request_with_incoming, user: user)
      end

      before { sign_in user }

      def answer(last_event_id)
        post alaveteli_pro_classifications_path(
          url_title: info_request.url_title
        ), params: {
          classification: { described_state: 'successful' },
          last_info_request_event_id: last_event_id
        }
      end

      it 'applies an answer from an up-to-date page' do
        answer(info_request.last_event_id_needing_description)
        expect(info_request.reload.described_state).to eq('successful')
      end

      it 'turns back an answer from a page loaded before something new came' do
        answer(info_request.last_event_id_needing_description + 1000)
        expect(flash[:error]).
          to match(/has been updated since you originally loaded this page/)
        expect(response).
          to redirect_to(show_request_path(url_title: info_request.url_title))
        expect(info_request.reload.described_state).not_to eq('successful')
      end
    end

    context 'when a non-pro user is allowed to update the request' do
      let(:user) { FactoryBot.create(:user) }

      include_examples 'classify request as successful'
    end

    shared_examples 'a state that needs a message' do |state|
      before { sign_in user }

      context 'without a message' do
        it 'should redirect to the add message page' do
          post_status(state)
          expect(response).to redirect_to(
            message_alaveteli_pro_classification_path(
              url_title: info_request.url_title,
              described_state: state
            )
          )
          expect(info_request.reload.described_state).
            to eq('waiting_response')
        end
      end

      context 'with a message' do
        it 'should create status_update log' do
          post_status(state, message: 'A message')

          event = InfoRequestEvent.last
          expect(event.event_type).to eq 'status_update'
          expect(event.params[:described_state]).to eq state
          expect(event.params[:old_described_state]).to eq 'waiting_response'
          expect(event.params[:message]).to eq 'A message'
          expect(event.params[:user]).to eq(user)
        end

        it 'should set the described state of the request' do
          post_status(state, message: 'A message')
          expect(info_request.reload.described_state).to eq(state)
        end

        it 'should redirect back to the request' do
          post_status(state, message: 'A message')
          expect(response).to redirect_to(
            show_request_path(url_title: info_request.url_title)
          )
        end
      end
    end

    context 'when the user sets the request as error_message' do
      include_examples 'a state that needs a message', 'error_message'
    end

    context 'when the user sets the request as requires_admin' do
      include_examples 'a state that needs a message', 'requires_admin'
    end
  end

  describe 'GET message' do
    include_examples 'adding classification message action'

    let(:user) { FactoryBot.create(:pro_user) }
    let(:info_request) { FactoryBot.create(:info_request, user: user) }
    let(:message_path) do
      message_alaveteli_pro_classification_path(
        url_title: info_request.url_title,
        described_state: 'error_message'
      )
    end
  end
end
