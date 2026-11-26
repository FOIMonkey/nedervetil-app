require 'spec_helper'

RSpec.describe 'admin/general/_status_update' do
  let(:info_request) { FactoryBot.create(:info_request) }

  def render_event(params)
    event = info_request.log_event('status_update', params)
    render partial: 'admin/general/status_update', locals: { event: event }
  end

  it 'names the user who updated the status' do
    render_event(user_id: info_request.user.id,
                 old_described_state: 'waiting_response',
                 described_state: 'successful')
    expect(rendered).to include("by #{info_request.user.name} from")
  end

  it 'names the administrator who reverted a report' do
    render_event(editor: 'an-admin',
                 old_described_state: 'attention_requested',
                 described_state: 'successful',
                 report_event_id: 1)
    expect(rendered).to include('by administrator an-admin from')
  end
end
