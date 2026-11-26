require 'spec_helper'

RSpec.describe 'Reverting a report from the admin request page', type: :request do
  around do |example|
    previous = ActionController::Base.allow_forgery_protection
    example.run
  ensure
    ActionController::Base.allow_forgery_protection = previous
  end

  let(:admin) { FactoryBot.create(:admin_user) }
  let(:info_request) do
    request = FactoryBot.create(:info_request)
    request.set_described_state('successful')
    request.report!('Vexatious', 'Please check', FactoryBot.create(:user))
    request
  end

  before { sign_in(admin) }

  it 'reverts with the page\'s authenticity token' do
    ActionController::Base.allow_forgery_protection = true
    get admin_request_path(info_request)
    form = Nokogiri::HTML(response.body).at_css('#revert_report form')
    token = form.at_css('input[name="authenticity_token"]')['value']
    report = form.at_css('input[name="report_event_id"]')['value']

    post revert_report_admin_request_path(info_request),
         params: { authenticity_token: token, report_event_id: report }

    expect(response).to redirect_to(admin_request_url(info_request))
    expect(info_request.reload.described_state).to eq('successful')
  end

  it 'still shows the report after an edit that left the status alone' do
    report = info_request.last_report_event
    patch admin_request_path(info_request), params: {
      info_request: { title: 'A clearer title',
                      described_state: info_request.described_state,
                      prominence: info_request.prominence }
    }
    get admin_request_path(info_request)

    section = Nokogiri::HTML(response.body).at_css('#revert_report')
    expect(section.text).to include('Reason: Vexatious')
    expect(section.at_css('input[name="report_event_id"]')['value']).
      to eq(report.id.to_s)
    expect(section.at_css('input[type="submit"]')['value']).
      to eq('Revert report')
    expect(section.text).to include('before it was reported (successful)')
  end

  it 'changes nothing without an authenticity token' do
    ActionController::Base.allow_forgery_protection = true

    post revert_report_admin_request_path(info_request),
         params: { report_event_id: info_request.last_report_event.id }

    expect(response).to have_http_status(422)
    expect(info_request.reload.described_state).to eq('attention_requested')
  end
end
