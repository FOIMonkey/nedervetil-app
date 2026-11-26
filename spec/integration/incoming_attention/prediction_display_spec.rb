require 'spec_helper'

RSpec.describe 'Prediction on the existing correspondence page' do
  self.use_transactional_tests = false

  before do
    @request_ids = []
    @user_ids = []
    @authority_ids = []
    @transport_calls = []
    allow(IncomingAttention::Config).to receive(:enabled?).and_return(true)
    allow(IncomingAttention::Job).
      to receive(:perform_later).and_return(double('queued'))
    allow(AlaveteliFeatures.backend).to receive(:enabled?).and_call_original
    allow(AlaveteliFeatures.backend).
      to receive(:enabled?).with(:alaveteli_pro).and_return(true)
    allow(Rails.application.config).
      to receive(:consider_all_requests_local).and_return(false)
    install_fake_worker
  end

  after do
    allow(IncomingAttention::Config).to receive(:enabled?).and_return(false)
    InfoRequest.where(id: @request_ids).find_each(&:destroy!)
    PublicBody.where(id: @authority_ids).find_each(&:destroy!)
    User.where(id: @user_ids).find_each(&:destroy!)
  end

  def synthetic_user(factory = :pro_user)
    user = FactoryBot.create(factory)
    @user_ids << user.id
    user
  end

  let(:owner) { synthetic_user.tap { |user| user.update!(trusted: true) } }
  let(:authority) do
    body = FactoryBot.create(:public_body)
    @authority_ids << body.id
    body
  end
  let(:info_request) do
    value = FactoryBot.create(:info_request, user: owner,
                                             public_body: authority,
                                             prominence: 'requester_only')
    @request_ids << value.id
    value
  end

  def receive_response
    target = info_request
    mail = Mail.new do
      from 'synthetic-officer@example.invalid'
      to target.incoming_email
      subject 'Synthetic private response'
      message_id "display-#{SecureRandom.uuid}@example.invalid"
      date Time.utc(2026, 10, 6, 12)
      content_type 'text/plain; charset=UTF-8'
      body "SYNTHETIC PRIVATE DISPLAY BODY café 😀\n\n> Complete synthetic " \
           "history."
    end
    target.send(:create_response!, mail, message_id: mail.message_id,
                                         message_checksum: Digest::SHA1.hexdigest(mail.encoded))
  end

  def install_fake_worker(verified: true)
    client = IncomingAttention::Client.new(transport: ->(input) do
      @transport_calls << input.deep_dup
      expect(ApplicationRecord.connection.transaction_open?).to eq(false)
      result = bounded_worker_response(input, eligible: verified, labels: {
                                         'routine' => 'ACKNOWLEDGEMENT',
                                         'attention' => nil
                                       })
      [200, JSON.generate(result)]
    end)
    allow(IncomingAttention::Job).
      to receive(:client_factory).and_return(-> { client })
  end

  def predict(message)
    row = IncomingAttention::Prediction.find_by!(
      incoming_message_id: message.id
    )
    IncomingAttention::Job.new.perform(row.id)
    expect(row.reload.status).to eq('complete')
    row
  end

  def page
    Nokogiri::HTML(response.body)
  end

  def widgets
    page.css('aside.incoming-prediction')
  end

  it 'shows an acknowledgement without internal diagnostics and starts it minimised' do
    row = predict(receive_response)
    sign_in(owner)
    get "/request/#{info_request.url_title}"
    expect(response).to have_http_status(:ok)
    expect(widgets).to be_empty
    expect(page.at_css("#reply-#{row.incoming_message_id} .feed__meta").text).
      to include('Acknowledgement')
    expect(
      page.at_css("#incoming-#{row.incoming_message_id}")['data-routine-update']
    ).to eq('true')
    expect(response.body).
      not_to include('input_fingerprint',
                     'Prediction scores',
                     'SKIP',
                     'coverage_verified')
    expect(response.body).to include('SYNTHETIC PRIVATE DISPLAY BODY')
    expect(@transport_calls.size).to eq(1)
  end

  it 'shows the substantive response in the reply’s row, and the routine choice at the foot of its letter' do
    row = predict(receive_response)
    row.update!(route: 'REVIEW', reply_labels: { 'routine' => 'ACKNOWLEDGEMENT',
                                                 'attention' => 'SUBSTANTIVE' })
    sign_in(owner)
    get "/request/#{info_request.url_title}"
    expect(page.at_css("#reply-#{row.incoming_message_id} .feed__meta").text).
      to include('Substantive response')
    expect(page.at_css('.receipt')).to be_nil
    expect(page.at_css("#reply-#{row.incoming_message_id}").key?('open')).
      to be(true)
    expect(page.at_css("#reply-#{row.incoming_message_id} " \
                       ".incoming-attention-choice button").text).
      to eq('File as routine')
    expect(
      page.at_css("#incoming-#{row.incoming_message_id}")['data-routine-update']
    ).to eq('false')
    expect(response.body).
      not_to include('Prediction scores', 'input_fingerprint')
  end

  # A suspended requester may not change the status, so has no choice to
  # make.
  it 'offers a suspended requester no routine choice' do
    row = predict(receive_response)
    row.update!(route: 'REVIEW', reply_labels: { 'routine' => 'ACKNOWLEDGEMENT',
                                                 'attention' => 'SUBSTANTIVE' })
    owner.update!(ban_text: 'Spam')
    sign_in(owner)
    get "/request/#{info_request.url_title}"
    expect(page.at_css("#reply-#{row.incoming_message_id} .feed__meta").text).
      to include('Substantive response')
    expect(page.at_css('.incoming-attention-choice')).to be_nil
  end

  it 'does not minimise ineligible or shortened mail even if the raw route is SKIP' do
    row = predict(receive_response)
    row.update!(eligible: false,
                restrictions: %w[input_truncated truncation_quoted_history])
    sign_in(owner)
    get "/request/#{info_request.url_title}"
    expect(page.css('.incoming-reply-type')).to be_empty
    expect(
      page.at_css("#reply-#{row.incoming_message_id} .feed__title").text
    ).to start_with('Reply from ')
    expect(
      page.at_css("#incoming-#{row.incoming_message_id}")['data-routine-update']
    ).to eq('false')
    expect(response.body).to include('SYNTHETIC PRIVATE DISPLAY BODY')
    expect(response.body).not_to include('input_fingerprint', 'input_truncated')
  end

  it 'keeps pending and failed correspondence readable without technical status or errors' do
    row = predict(receive_response)
    sign_in(owner)
    row.invalidate!(reason: 'attachment_created')
    get "/request/#{info_request.url_title}"
    expect(page.css('.incoming-reply-type')).to be_empty
    expect(response.body).
      not_to include('attachment_created', 'Status: stale', 'Prediction scores')
    expect(response.body).to include('SYNTHETIC PRIVATE DISPLAY BODY')
    row.update!(status: 'failed', error_code: 'transport_failure')
    get "/request/#{info_request.url_title}"
    expect(page.css('.incoming-reply-type')).to be_empty
    expect(
      page.at_css("#reply-#{row.incoming_message_id} .feed__title").text
    ).to start_with('Reply from ')
    expect(response.body).not_to include('transport_failure')
  end

  it 'preserves private correspondence authorization for visitors and other owners' do
    predict(receive_response)
    [nil, synthetic_user].each do |reader|
      sign_in(reader) if reader
      get "/request/#{info_request.url_title}"
      expect(response).not_to have_http_status(:ok)
      expect(page.css('.incoming-reply-type')).to be_empty
      expect(response.body).
        not_to include('input_fingerprint', 'SYNTHETIC PRIVATE DISPLAY BODY')
    end
  end

  it 'keeps diagnostic fields hidden for an authorized administrator too' do
    predict(receive_response)
    sign_in(synthetic_user(:admin_user))
    get "/request/#{info_request.url_title}"
    expect(response).to have_http_status(:ok)
    expect(page.at_css('.incoming-reply-type').text).
      to include('Acknowledgement')
    expect(response.body).
      not_to include('input_fingerprint', 'Prediction scores')
  end

  it 'rechecks hidden-message and reassigned-request permissions' do
    message = receive_response
    predict(message)
    sign_in(owner)
    message.update!(prominence: 'hidden')
    get "/request/#{info_request.url_title}"
    expect(response.body).
      not_to include('SYNTHETIC PRIVATE DISPLAY BODY', 'input_fingerprint')
    expect(page.css('.incoming-reply-type')).to be_empty
    info_request.update_columns(user_id: synthetic_user.id)
    get "/request/#{info_request.url_title}"
    expect(response).not_to have_http_status(:ok)
  end

  it 'preserves the ordinary expanded correspondence view with the flag off' do
    row = predict(receive_response)
    allow(IncomingAttention::Config).to receive(:enabled?).and_return(false)
    sign_in(owner)
    get "/request/#{info_request.url_title}"
    expect(page.css('.incoming-reply-type')).to be_empty
    expect(
      page.at_css("#incoming-#{row.incoming_message_id}")['data-routine-update']
    ).to eq('false')
    expect(@transport_calls.size).to eq(1)
  end

  it 'retains the existing owner status form and accepts a human classification without rewriting the prediction' do
    row = predict(receive_response)
    before = row.attributes
    sign_in(owner)
    get "/request/#{info_request.url_title}?update_status=1"
    expect(response).to have_http_status(:ok)
    expect(page.css('input[value="successful"]')).not_to be_empty
    event_id = info_request.reload.last_event_id_needing_description
    post "/request/#{info_request.url_title}/classifications", params: {
      classification: { described_state: 'successful' },
      last_info_request_event_id: event_id
    }
    expect(response).to redirect_to("/request/#{info_request.url_title}")
    expect(info_request.reload.described_state).to eq('successful')
    expect(info_request.awaiting_description).to eq(false)
    expect(row.reload.attributes.except('human_reviewed_at')).
      to eq(before.except('human_reviewed_at'))
    expect(row.human_reviewed_at).to be_present
    expect(@transport_calls.size).to eq(1)
  end
  it 'lets the requester promote an automatically accepted acknowledgement' do
    message = receive_response
    row = predict(message)
    expect(info_request.reload.awaiting_description?).to be false
    sign_in(owner)
    post "/request/#{info_request.url_title}/attention_choice", params: {
      incoming_message_id: message.id, incoming_attention_choice: 'attention'
    }
    expect(response).to have_http_status(:redirect)
    expect(row.reload.attention_override).to eq('attention')
    expect(info_request.reload.awaiting_description?).to be true
    expect(IncomingAttention::Effective.dashboard_attention(
             IncomingMessage.where(id: message.id)
           )).to exist
  end

  it 'lets the requester file a promoted reply as routine again, and the request stops waiting' do
    message = receive_response
    row = predict(message)
    sign_in(owner)
    post "/request/#{info_request.url_title}/attention_choice", params: {
      incoming_message_id: message.id, incoming_attention_choice: 'attention'
    }
    expect(info_request.reload.awaiting_description?).to be true
    get "/request/#{info_request.url_title}"
    form = page.at_css('form.incoming-attention-choice')
    expect(form.at_css('button').text).to eq('File as routine')
    post form['action'], params: {
      incoming_message_id:
        form.at_css('input[name="incoming_message_id"]')['value'],
      incoming_attention_choice: 'routine'
    }
    expect(response).
      to redirect_to(
        "/request/#{info_request.url_title}#incoming-#{message.id}"
      )
    expect(row.reload.attention_override).to eq('routine')
    expect(info_request.reload.awaiting_description?).to be false
    post "/request/#{info_request.url_title}/attention_choice", params: {
      incoming_message_id: message.id, incoming_attention_choice: 'bogus'
    }
    expect(response).to have_http_status(:bad_request)
    expect(row.reload.attention_override).to eq('routine')
  end

  it 'does not let another requester change private correspondence attention' do
    message = receive_response
    row = predict(message)
    sign_in(synthetic_user)
    post "/request/#{info_request.url_title}/attention_choice", params: {
      incoming_message_id: message.id, incoming_attention_choice: 'attention'
    }
    expect(row.reload.attention_override).to be_nil
  end

  it 'rechecks requester ownership after the request is locked' do
    message = receive_response
    row = predict(message)
    sign_in(owner)
    other = synthetic_user
    before = row.attributes
    allow_any_instance_of(InfoRequest).
      to receive(:with_lock).and_wrap_original do |original, *args, &block|
      info_request.update_columns(user_id: other.id)
      original.call(*args, &block)
    end
    post "/request/#{info_request.url_title}/attention_choice", params: {
      incoming_message_id: message.id, incoming_attention_choice: 'attention'
    }
    expect(row.reload.attributes).to eq(before)
    expect(info_request.reload.awaiting_description?).to be false
  end

  it 'rechecks message association after the request is locked' do
    message = receive_response
    row = predict(message)
    sign_in(owner)
    destination = FactoryBot.create(:info_request, user: owner,
                                                   public_body: authority)
    @request_ids << destination.id
    before = row.attributes
    allow_any_instance_of(InfoRequest).
      to receive(:with_lock).and_wrap_original do |original, *args, &block|
      message.update_columns(info_request_id: destination.id)
      original.call(*args, &block)
    end
    post "/request/#{info_request.url_title}/attention_choice", params: {
      incoming_message_id: message.id, incoming_attention_choice: 'attention'
    }
    expect(response).to have_http_status(:not_found)
    expect(row.reload.attributes).to eq(before)
    expect(info_request.reload.awaiting_description?).to be false
  end

  it 'rechecks fresh message read permission before a correction or Dismiss write' do
    %w[attention].each do |choice|
      message = receive_response
      row = predict(message)
      sign_in(owner)
      before = row.attributes
      allow_any_instance_of(InfoRequest).
        to receive(:with_lock).and_wrap_original do |original, *args, &block|
        message.update_columns(prominence: 'hidden')
        original.call(*args, &block)
      end
      post "/request/#{info_request.url_title}/attention_choice", params: {
        incoming_message_id: message.id, incoming_attention_choice: choice
      }
      expect(row.reload.attributes).to eq(before)
    end
  end

  it 'allows Dismiss only for the requester and only for routine mail, with no arbitrary return URL' do
    message = receive_response
    row = predict(message)
    sign_in(synthetic_user)
    post "/request/#{info_request.url_title}/attention_dismissal", params: {
      incoming_message_ids: [message.id]
    }
    expect(row.reload.human_reviewed_at).to be_nil
    sign_in(owner)
    row.update!(attention_override: 'attention')
    post "/request/#{info_request.url_title}/attention_dismissal", params: {
      incoming_message_ids: [message.id]
    }
    expect(response).to have_http_status(:redirect)
    expect(row.reload.human_reviewed_at).to be_nil
    row.update!(attention_override: 'routine')
    before = info_request.reload.attributes
    post "/request/#{info_request.url_title}/attention_dismissal", params: {
      incoming_message_ids: [message.id],
      incoming_attention_return: 'https://example.invalid/'
    }
    expect(response).
      to redirect_to(
        "/request/#{info_request.url_title}#incoming-#{message.id}"
      )
    expect(row.reload.human_reviewed_at).to be_present
    expect(info_request.reload.attributes).to eq(before)
  end
end
