require 'spec_helper'

RSpec.describe 'The "Under appeal" status', type: :request do
  include_context 'with incoming attention off'

  let(:user) { FactoryBot.create(:user) }
  let(:info_request) { FactoryBot.create(:info_request, user: user) }

  it 'is a valid state with a name' do
    expect(InfoRequest::State.all).to include('under_appeal')
    expect(InfoRequest.get_status_description('under_appeal')).
      to eq('Under appeal')
    expect(InfoRequest::State.short_description('under_appeal')).
      to eq('Under appeal')
  end

  it 'is the status of a request described that way' do
    info_request.set_described_state('under_appeal')

    expect(info_request.reload.calculate_status).to eq('under_appeal')
    expect(info_request.display_status).to eq('Under appeal')
  end

  it 'is offered once to the requester when they update the status' do
    sign_in! user
    get "/request/#{info_request.url_title}?update_status=1"

    form = Nokogiri::HTML(response.body).at_css('form[id^="describe_form"]')
    expect(form.css('input[value="under_appeal"]').size).to eq(1)
    expect(form.text).to include('appealed to the regulator or a tribunal')
  end

  it 'is not offered to someone else classifying an old request' do
    info_request.update!(awaiting_description: true)
    transitions = info_request.state.transitions(
      is_owning_user: false, user_asked_to_update_status: false
    )

    expect(transitions[:pending].keys).not_to include('under_appeal')
  end

  it 'can be chosen, and is then shown in words' do
    sign_in! user
    get "/request/#{info_request.url_title}?update_status=1"

    post "/request/#{info_request.url_title}/classifications", params: {
      classification: { described_state: 'under_appeal' },
      last_info_request_event_id:
        info_request.reload.last_event_id_needing_description
    }

    expect(response).to redirect_to("/request/#{info_request.url_title}")
    expect(info_request.reload.described_state).to eq('under_appeal')

    follow_redirect!
    expect(response.body).
      to include('This request is now marked as under appeal.', 'Under appeal')
  end

  it 'counts as Other in the requester\'s summaries and filter' do
    info_request.set_described_state('under_appeal')

    expect(info_request.state.phase).to eq(:other)
    expect(user.info_requests.other).to include(info_request)

    with_feature_enabled(:alaveteli_pro) do
      sign_in! user
      get alaveteli_pro_info_requests_path,
          params: { alaveteli_pro_request_filter: { filter: 'other' } }
      expect(response.body).to include(info_request.title, 'Under appeal')
    end
  end
end
