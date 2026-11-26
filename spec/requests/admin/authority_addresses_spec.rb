require 'spec_helper'

RSpec.describe 'Admin authority addresses', type: :request do
  let(:redirect_address) { 'owner@closed.example.test' }
  let(:stored_address) { 'foi@authority.example.test' }
  let(:body) do
    FactoryBot.create(:public_body, request_email: stored_address)
  end

  before do
    allow(AlaveteliConfiguration).
      to receive(:override_all_public_body_request_emails).
      and_return(redirect_address)
    # Arrange a fully authenticated admin; production has no test-only
    # bypass.
    sign_in FactoryBot.create(:admin_user)
  end

  def email_field
    Nokogiri::HTML(response.body).
      at_css('input[name="public_body[request_email]"]')
  end

  it 'shows the stored authority address and explains the active redirect' do
    get admin_body_path(body)
    expect(response).to be_successful
    expect(response.body).to include("mailto:#{stored_address}")
    expect(response.body).not_to include("mailto:#{redirect_address}")
    expect(response.body).
      to include('The authority address is saved as entered.',
                 redirect_address)
  end

  it 'edits the stored address while request delivery uses the override' do
    get edit_admin_body_path(body)
    expect(email_field['value']).to eq(stored_address)
    expect(body.reload.request_email).to eq(redirect_address)
  end

  it 'keeps the real address when the displayed form is saved again' do
    get edit_admin_body_path(body)
    address = email_field['value']
    put admin_body_path(body), params: { public_body: {
      locale: AlaveteliLocalization.default_locale, name: body.name,
      request_email: address, last_edit_comment: 'Update the source note'
    } }
    expect(response).to redirect_to(admin_body_path(body))
    expect(body.reload.read_attribute(:request_email)).to eq(stored_address)
    expect(body.request_email).to eq(redirect_address)
  end

  it 'stores a changed address without changing the delivery override' do
    put admin_body_path(body), params: { public_body: {
      locale: AlaveteliLocalization.default_locale, name: body.name,
      request_email: 'new@authority.example.test'
    } }
    expect(response).to redirect_to(admin_body_path(body))
    expect(body.reload.read_attribute(:request_email)).
      to eq('new@authority.example.test')
    expect(body.request_email).to eq(redirect_address)
  end

  it 'creates an authority with its entered address and sends no email' do
    count = ActionMailer::Base.deliveries.size
    post admin_bodies_path, params: { public_body: {
      locale: AlaveteliLocalization.default_locale,
      name: 'Synthetic Address Authority',
      request_email: stored_address
    } }
    created = PublicBody.find_by!(url_name: 'synthetic_address_authority')
    expect(response).to redirect_to(admin_body_path(created))
    expect(created.read_attribute(:request_email)).to eq(stored_address)
    expect(created.request_email).to eq(redirect_address)
    expect(ActionMailer::Base.deliveries.size).to eq(count)
  end

  it 'retains the entered address when validation needs another correction' do
    put admin_body_path(body), params: { public_body: {
      locale: AlaveteliLocalization.default_locale, name: '',
      request_email: 'new@authority.example.test'
    } }
    expect(response).to have_http_status(:unprocessable_content)
    expect(response.body).to include('Edit public body')
    expect(email_field['value']).to eq('new@authority.example.test')
    expect(body.reload.read_attribute(:request_email)).to eq(stored_address)
  end

  it 'leaves the new-authority email field empty' do
    get new_admin_body_path
    expect(response).to have_http_status(:ok)
    expect(email_field).to be_present
    expect(email_field['value'].to_s).to eq('')
  end

  it 'uses the stored address and no redirect notice when the override is off' do
    allow(AlaveteliConfiguration).
      to receive(:override_all_public_body_request_emails).and_return('')
    get admin_body_path(body)
    expect(response.body).to include("mailto:#{stored_address}")
    expect(response.body).
      not_to include('The authority address is saved as entered.')
    get edit_admin_body_path(body)
    expect(email_field['value']).to eq(stored_address)
    expect(body.reload.request_email).to eq(stored_address)
  end
end
