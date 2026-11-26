require 'spec_helper'

RSpec.describe 'Admin change requests', type: :request do
  # Arrange a fully authenticated admin; production has no test-only bypass.
  before { sign_in FactoryBot.create(:admin_user) }

  let(:add_request) { FactoryBot.create(:add_body_request) }
  let(:page) { Nokogiri::HTML(response.body) }

  describe 'GET index' do
    it 'links safe source URLs via source_link and renders unsafe legacy ' \
       'values as plain text' do
      add_request.update_column(:source_url, 'javascript:alert(1)')
      FactoryBot.create(:add_body_request, source_url: 'example.org/foi')

      get admin_change_requests_path
      expect(response).to have_http_status(:ok)
      expect(page.at_css('a[href^="javascript:"]')).to be_nil
      expect(response.body).to include('javascript:alert(1)')
      expect(page.at_css('a[href="https://example.org/foi"]')).to be_present
    end
  end

  describe 'GET edit' do
    it 'titles the page for a full edit and shows the full form' do
      get edit_admin_change_request_path(add_request, full_edit: true)
      expect(response).to have_http_status(:ok)
      expect(page.at_css('.page-header h1').text).
        to eq('Edit change request')
      expect(page.at_css('input[name="change_request[source_url]"]')).
        to be_present
    end

    it 'titles the page for closing the request and shows the close form' do
      get edit_admin_change_request_path(add_request)
      expect(response).to have_http_status(:ok)
      expect(page.at_css('.page-header h1').text).
        to eq('Close change request')
      expect(page.at_css('#change_request_user_subject_field')).to be_present
      expect(page.at_css('#change_request_user_response_field')).
        to be_present
      expect(page.at_css('input[name="change_request[source_url]"]')).
        to be_nil
    end
  end

  describe 'PUT update' do
    before do
      put admin_change_request_path(add_request), params: params
    end

    context 'a full edit with a source that is not a web address' do
      let(:params) do
        { commit: 'Save',
          change_request: { source_url: 'javascript:alert(1)' } }
      end

      it 'shows the form again with the error, saving nothing' do
        expect(response).to have_http_status(422)
        expect(page.at_css('input[name="change_request[source_url]"]')).
          to be_present
        expect(flash[:error]).to include('Please enter a web address')
        expect(response.body).to include('Please enter a web address')
        expect(add_request.reload.source_url).not_to eq('javascript:alert(1)')
      end
    end

    context 'close and respond' do
      let(:params) do
        { response: 'Thanks but no',
          subject: 'Your request' }
      end

      it 'closes the change request' do
        expect(add_request.reload.is_open).to eq(false)
      end

      it 'sends a response email to the user who requested the change' do
        deliveries = ActionMailer::Base.deliveries
        mail = deliveries.first

        expect(deliveries.size).to eq(1)
        expect(mail.subject).to eq('Your request')
        expect(mail.to).to eq([add_request.requester_email])
        expect(mail.body).to match(/Thanks but no/)
      end

      it 'notifies the admin the request is closed and user has been emailed' do
        msg =
          'The change request has been closed and the user has been notified'

        expect(flash[:notice]).to eq(msg)
      end

      it 'redirects to the admin summary' do
        expect(response).to redirect_to(admin_general_index_path)
      end
    end

    context 'close' do
      let(:params) { {} }

      it 'closes the change request' do
        expect(add_request.reload.is_open).to eq(false)
      end

      it 'no email is sent to the user who requested the change' do
        expect(ActionMailer::Base.deliveries).to be_empty
      end

      it 'notifies the admin the request is closed' do
        expect(flash[:notice]).to eq('The change request has been closed')
      end

      it 'redirects to the admin summary' do
        expect(response).to redirect_to(admin_general_index_path)
      end
    end
  end
end
