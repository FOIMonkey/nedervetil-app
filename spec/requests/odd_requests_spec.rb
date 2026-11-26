require 'spec_helper'

# A request that no page or form would send gets a refusal, the form again or
# a 404, and never the error page: a form sent without its fields, or an
# address that names nothing.
RSpec.describe 'A request no page would send', type: :request do
  include_context 'consider all requests remote'

  let(:owner) { FactoryBot.create(:user, name: 'Rowan Requester') }
  let(:info_request) do
    FactoryBot.create(:info_request_with_incoming, user: owner)
  end
  let(:refusal) { "This form couldn't be sent" }

  describe 'a form sent without its fields' do
    it 'is refused when it asks for an authority to be added or changed' do
      post change_request_path

      expect(response).to have_http_status(:bad_request)
      expect(response.body).to include(refusal)
    end

    it 'is refused when it sets whether to send email alerts' do
      sign_in(owner)
      post set_receive_email_alerts_path

      expect(response).to have_http_status(:bad_request)
      expect(response.body).to include(refusal)
      expect(owner.reload.receive_email_alerts).to be(true)
    end

    it 'is refused when it changes an account’s name' do
      sign_in(owner)
      patch users_name_path

      expect(response).to have_http_status(:bad_request)
      expect(response.body).to include(refusal)
    end

    it 'shows the follow-up form again, as for an empty message' do
      sign_in(owner)
      post request_followups_path(request_url_title: info_request.url_title)

      expect(response).to have_http_status(422)
      expect(response.body).to include('id="followup"')
    end

    it 'asks for a reason when a report gives none' do
      sign_in(owner)
      post request_report_path(request_url_title: info_request.url_title)

      expect(response).to have_http_status(422)
      expect(response.body).to include('Please choose a reason')
    end
  end

  describe 'a link that would change a setting' do
    it 'changes nothing: email alerts are set by a form alone' do
      sign_in(owner)
      get '/profile/set_receive_alerts',
          params: { receive_email_alerts: 'false', came_from: '/' }

      expect(response).to have_http_status(:not_found)
      expect(owner.reload.receive_email_alerts).to be(true)
    end
  end

  describe 'an address that names nothing' do
    it 'is not found: a due date for something that is not a date' do
      get '/due_date/next-tuesday'

      expect(response).to have_http_status(:not_found)
    end

    it 'still works out a due date for a date' do
      get '/due_date/2026-11-12'

      expect(response).to have_http_status(:ok)
    end

    it 'is not found: the message page of a state that has none' do
      sign_in(owner)
      get message_classification_path(url_title: info_request.url_title,
                                      described_state: 'successful')

      expect(response).to have_http_status(:not_found)
    end

    it 'is not found: a new admin note that applies to nothing' do
      sign_in(FactoryBot.create(:admin_user))
      get new_admin_note_path

      expect(response).to have_http_status(:not_found)
    end
  end
end
