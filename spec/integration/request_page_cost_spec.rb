require 'spec_helper'

RSpec.describe 'The request page' do
  include_context 'with incoming attention off'
  let(:user) { FactoryBot.create(:pro_user) }

  def request_with_replies
    request = FactoryBot.create(:info_request, user: user)
    3.times do
      message = FactoryBot.create(:incoming_message, info_request: request)
      request.log_event('response', incoming_message_id: message.id)
    end
    request
  end

  it 'loads the censor rules and checks their flag once, however many rules apply' do
    request = request_with_replies
    10.times do |i|
      FactoryBot.create(:global_censor_rule, text: "zq-nothing-matches-#{i}")
    end
    sign_in(user)
    # The first view builds and stores each reply's body, which reads the
    # rules afresh.
    get "/request/#{request.url_title}"
    allow(AlaveteliFeatures.backend).to receive(:enabled?).and_call_original
    rule_loads = 0
    counter = ->(*, payload) do
      rule_loads += 1 if payload[:sql].include?('FROM censor_rules cr')
    end
    ActiveSupport::Notifications.subscribed(counter, 'sql.active_record') do
      get "/request/#{request.url_title}"
    end

    expect(response).to have_http_status(:ok)
    expect(rule_loads).to eq(1)
    expect(AlaveteliFeatures.backend).
      to have_received(:enabled?).with(:redaction_tracking).once
  end

  it 'loads the censor rules afresh outside the page' do
    request = request_with_replies
    before = request.applicable_censor_rules.size
    rule = FactoryBot.create(:global_censor_rule)
    expect(request.applicable_censor_rules.size).to eq(before + 1)
    expect(request.applicable_censor_rules).to include(rule)
  end

  it 'reads the rules afresh for masks core stores, while the page keeps its copy' do
    request = request_with_replies
    message = request.incoming_messages.first
    attachment = message.foi_attachments.first ||
                 FactoryBot.create(:body_text, incoming_message: message)
    seen = {}
    Current.memoising do
      request.applicable_censor_rules
      rule = FactoryBot.create(:global_censor_rule)
      allow_any_instance_of(FoiAttachment).to receive(:mask) do |part|
        seen[:mask] = part.info_request.applicable_censor_rules.include?(rule)
      end
      FoiAttachment::MaskJob.new.perform(attachment)
      allow(message).to receive(:get_main_body_text_internal) do
        rules = message.info_request.applicable_censor_rules
        seen[:body] = rules.include?(rule)
        'Body text'
      end
      message.send(:_cache_main_body_text)
      seen[:page] = request.applicable_censor_rules.include?(rule)
    end

    expect(seen).to eq(mask: true, body: true, page: false)
  end

  it 'runs no similar-requests search' do
    request = request_with_replies
    # SearchHelpers answers every search with nothing; this uses the real
    # adapter.
    SearchHelpers.stubbed = false
    allow(Search).to receive(:typeahead).and_call_original
    sign_in(user)
    get "/request/#{request.url_title}"
    expect(response).to have_http_status(:ok)

    reset!
    sign_in(FactoryBot.create(:admin_user))
    get "/request/#{request.url_title}"
    expect(response).to have_http_status(:ok)
    expect(Nokogiri::HTML(response.body).at_css('#left_column')).to be_present
    expect(Search).not_to have_received(:typeahead)
    expect(request).not_to respond_to(:similar_requests)
    expect(Search).not_to respond_to(:similar)
  end
end
