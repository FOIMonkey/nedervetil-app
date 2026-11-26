require 'spec_helper'

RSpec.describe 'Admin triage detail pane', type: :request do
  let(:admin) { FactoryBot.create(:admin_user) }
  let(:user) { FactoryBot.create(:user) }
  def page
    Nokogiri::HTML(response.body)
  end

  it 'is not found for a non-admin user' do
    info_request = FactoryBot.create(:attention_requested_request)
    sign_in(user)
    get admin_triage_path('request', info_request.id)
    expect(response).to have_http_status(:not_found)
  end

  context 'as an admin' do
    before { sign_in(admin) }

    it 'renders a reported request in triage_detail as a frame or full page' do
      info_request = FactoryBot.create(:attention_requested_request)

      get admin_triage_path('request', info_request.id)
      expect(response).to have_http_status(:ok)
      expect(page.at_css('body.admin')).to be_present
      expect(page.at_css('turbo-frame#triage_detail')).to be_present
      expect(response.body).
        to include(info_request.title, 'Hide from requester')

      get admin_triage_path('request', info_request.id),
          headers: { 'Turbo-Frame' => 'triage_detail' }
      expect(response).to have_http_status(:ok)
      expect(response.headers['Cache-Control']).to eq('private, no-store')
      expect(response.headers['Vary']).to include('Turbo-Frame')
      expect(page.at_css('body.admin')).to be_nil
      expect(page.at_css('turbo-frame#triage_detail')).to be_present
    end

    it 'renders a holding-pen message with redelivery actions' do
      msg = FactoryBot.create(:incoming_message,
                              info_request: InfoRequest.holding_pen_request)
      get admin_triage_path('holding_pen', msg.id),
          headers: { 'Turbo-Frame' => 'triage_detail' }
      expect(response).to have_http_status(:ok)
      expect(response.body).
        to include(admin_incoming_message_redelivery_path(msg))
    end

    it 'renders an authority change request with close and edit actions' do
      cr = FactoryBot.create(:update_body_request)
      get admin_triage_path('change_request', cr.id),
          headers: { 'Turbo-Frame' => 'triage_detail' }
      expect(response).to have_http_status(:ok)
      expect(response.body).
        to include(admin_change_request_path(cr),
                   edit_admin_change_request_path(cr))
    end

    it 'renders a request preview inside the request_preview turbo frame' do
      info_request = FactoryBot.create(:info_request)
      get admin_triage_path('request_preview', info_request.id),
          headers: { 'Turbo-Frame' => 'request_preview' }
      expect(response).to have_http_status(:ok)
      expect(page.at_css('turbo-frame#request_preview')).to be_present
      expect(response.body).to include(info_request.title)
    end
  end
end
