require 'spec_helper'

# The admin page's report section for the two reports that don't come from
# the report form: the requester classifying the request as needing an admin,
# and an admin setting that status in Edit metadata.
RSpec.describe 'Report details on the admin request page', type: :request do
  let(:admin) { FactoryBot.create(:admin_user) }
  let(:requester) { FactoryBot.create(:user, name: 'Rhoda Requester') }
  let(:info_request) do
    request = FactoryBot.create(:info_request, user: requester)
    request.set_described_state('successful')
    request
  end

  def report_section
    reset!
    sign_in(admin)
    get admin_request_path(info_request)
    expect(response).to have_http_status(:ok)
    Nokogiri::HTML(response.body).at_css('#revert_report')
  end

  it 'shows a requester who classified it as needing an admin' do
    sign_in(requester)
    post classifications_path(url_title: info_request.url_title), params: {
      classification: { described_state: 'requires_admin',
                        message: 'Something is wrong here' },
      last_info_request_event_id:
        info_request.last_event_id_needing_description
    }
    expect(info_request.reload.described_state).to eq('requires_admin')

    section = report_section

    expect(section.text.squish).to include('by Rhoda Requester')
    expect(section.at_css('.admin-report-message').text).
      to include('Something is wrong here')
    expect(section.at_css('input[name="report_event_id"]')['value']).
      to eq(info_request.last_report_event.id.to_s)
    expect(section.at_css('input[type="submit"]')['value']).
      to eq('Revert report')
    expect(section.text).to include('before it was reported (successful)')
  end

  it 'shows an admin who set it as needing an admin in Edit metadata' do
    sign_in(admin)
    patch admin_request_path(info_request), params: {
      info_request: { title: info_request.title,
                      described_state: 'requires_admin',
                      prominence: info_request.prominence }
    }
    expect(info_request.reload.described_state).to eq('requires_admin')

    section = report_section

    expect(section.text.squish).to include("by administrator #{admin.url_name}")
    expect(section.at_css('input[name="report_event_id"]')['value']).
      to eq(info_request.last_report_event.id.to_s)
    expect(section.at_css('input[type="submit"]')['value']).
      to eq('Revert report')
    expect(section.text).to include('before it was reported (successful)')
  end
end
