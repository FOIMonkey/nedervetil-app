require 'spec_helper'

RSpec.shared_examples 'batch privacy surfaces' do
  let(:owner) { FactoryBot.create(:user, trusted: true) }
  let(:batch) {
    FactoryBot.create(:info_request_batch,
                      :sent,
                      user: owner,
                      public_body_count: 2)
  }
  let(:visible_child) { batch.info_requests.order(:id).first }
  let(:private_child) { batch.info_requests.order(:id).last }
  let(:secret_body) {
    'This private reassigned correspondence must stay with ' \
    'its new requester.'
  }

  before do
    allow(AlaveteliFeatures.backend).to receive(:enabled?).and_call_original
    allow(AlaveteliFeatures.backend).
      to receive(:enabled?).with(:alaveteli_pro).and_return(true)
    allow(Rails.application.config).
      to receive(:consider_all_requests_local).and_return(false)
    private_child.update!(user: FactoryBot.create(:user),
                          title: 'Reassigned private child title')
    private_child.outgoing_messages.first.update!(body: secret_body)
    batch.create_or_update_request_summary
    expect(Ability.new(owner).can?(:read, private_child.reload)).to eq(false)
  end

  it 'omits unreadable children and their body excerpts from the direct batch page' do
    sign_in(owner)
    get show_alaveteli_pro_batch_request_path(batch)
    expect(response).to have_http_status(:ok)
    expect(response.body).to include(visible_child.title)
    expect(response.body).
      not_to include(private_child.title, private_child.url_title, secret_body)
  end

  it 'does not expose the body of an unreadable initial message through a readable batch child' do
    message = visible_child.outgoing_messages.first
    message.update!(prominence: 'hidden',
                    body: 'Hidden initial message content must remain hidden.')
    expect(Ability.new(owner).can?(:read, visible_child)).to eq(true)
    expect(Ability.new(owner).can?(:read, message)).to eq(false)
    sign_in(owner)
    get show_alaveteli_pro_batch_request_path(batch)
    expect(response).to have_http_status(:ok)
    expect(response.body).to include(visible_child.title)
    expect(response.body).not_to include(message.body)
  end

  it 'omits unreadable private children from batch cards and recipient metadata' do
    sign_in(owner)
    get alaveteli_pro_info_requests_path
    expect(response).to have_http_status(:ok)
    expect(response.body).
      not_to include("id=\"info-request-#{private_child.id}\"",
                     private_child.url_title,
                                       private_child.public_body.name)
    expect(response.body).to include(visible_child.public_body.name)
  end

  it 'exports only readable children in the CSV endpoint' do
    sign_in(owner)
    get "/pro/info_request_batches/#{batch.id}/download.csv"
    expect(response).to have_http_status(:ok)
    expect(CSV.parse(response.body,
                     headers: true).map { |row| row['request_url'] }).to eq(
                       ["http://test.host/request/#{visible_child.url_title}"]
                     )
  end

  it 'exports only readable children in the embedded ZIP dashboard and correspondence' do
    files = InfoRequestBatchZip.new(batch, ability: Ability.new(owner)).files
    metrics = files.find { |file| file.path.end_with?('.csv') }
    expect(CSV.parse(metrics.body,
                     headers: true).map { |row| row['request_url'] }).to eq(
                       ["http://test.host/request/#{visible_child.url_title}"]
                     )
    expect(files.map(&:body).join).
      not_to include(private_child.url_title, secret_body)
  end

  it 'preserves authorized administrator access to every private child' do
    admin = FactoryBot.create(:admin_user)
    sign_in(admin)
    get info_request_batch_path(batch)
    expect(response).to have_http_status(:ok)
    # The batch page lists each child without repeating the request text.
    expect(response.body).to include(private_child.title)
    get request_path(private_child)
    expect(response).to have_http_status(:ok)
    expect(response.body).to include(secret_body)
    get "/pro/info_request_batches/#{batch.id}/download.csv"
    expect(response).to have_http_status(:ok)
    expect(CSV.parse(response.body, headers: true).size).to eq(2)
  end
end

RSpec.describe 'Batch privacy independent of incoming-mail prediction' do
  [false, true].each do |flag|
    context "with the incoming-mail feature flag #{flag}" do
      before {
        allow(AlaveteliConfiguration).
          to receive(:incoming_attention_enabled).and_return(flag)
      }
      include_examples 'batch privacy surfaces'
    end
  end
end
