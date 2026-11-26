require 'spec_helper'

RSpec.describe 'Anonymous draft admission', type: :request do
  include_context 'consider all requests remote'
  let(:authority) { FactoryBot.create(:public_body) }
  let(:origin) { { 'Origin' => "http://#{host}" } }

  def submit_letter(number, address: '192.0.2.1')
    post new_request_path, params: {
      submitted_new_request: 1,
      info_request: { title: "Invented library totals #{number}",
                      public_body_id: authority.id },
      outgoing_message: {
        body: "Dear Authority,\n" \
              "Please supply the invented library totals.\n" \
              "Yours faithfully,\n" \
              "Example Author"
      }
    }, headers: origin.merge('REMOTE_ADDR' => address)
  end

  it 'replaces the previous browser-owned body and admits only ten posts per IP' do
    10.times do |number|
      submit_letter(number)
      expect(response).to redirect_to(signup_path)
      expect(PendingRequestDraft.count).to eq(1)
    end
    kept = PendingRequestDraft.last
    expect { submit_letter(11) }.not_to change(PendingRequestDraft, :count)
    expect(response).to have_http_status(:too_many_requests)
    expect(JSON.parse(kept.reload.payload)['title']).
      to eq('Invented library totals 9')
    expect(ActionMailer::Base.deliveries).to be_empty
    travel 11.minutes do
      submit_letter(12)
      expect(response).to redirect_to(signup_path)
      expect(PendingRequestDraft.count).to eq(1)
    end
  end

  it 'does not let clearing the browser state bypass the IP limit' do
    10.times do |number|
      reset!
      submit_letter(number)
      expect(response).to redirect_to(signup_path)
    end
    reset!
    expect { submit_letter(11) }.not_to change(PendingRequestDraft, :count)
    expect(response).to have_http_status(:too_many_requests)
  end

  it 'caps site-wide admission even when addresses and browser state change' do
    100.times do |number|
      reset!
      submit_letter(number, address: "192.0.2.#{number + 1}")
      expect(response).to redirect_to(signup_path)
    end
    reset!
    expect do
      submit_letter(101, address: '192.0.2.101')
    end.not_to change(PendingRequestDraft, :count)
    expect(response).to have_http_status(:too_many_requests)
  end

  it 'does not charge GETs against admission or block an authenticated draft' do
    11.times { get new_request_path }
    10.times { |number| submit_letter(number) }
    sign_in(FactoryBot.create(:user))
    expect { submit_letter(11) }.to change(DraftInfoRequest, :count).by(1)
    expect(response).to have_http_status(:redirect)
  end
end
