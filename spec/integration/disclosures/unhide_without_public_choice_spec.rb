require 'spec_helper'

RSpec.describe 'Bringing back a hidden file without a public prominence choice',
               type: :request do
  include ActiveJob::TestHelper
  include DisclosuresHelpers
  include_context 'with document OCR off'
  include_context 'with production error pages'

  let(:owner) { FactoryBot.create(:user, name: 'Rowan Requester') }
  let(:publisher) { FactoryBot.create(:admin_user, name: 'Petra Publisher') }
  let(:admin) { FactoryBot.create(:admin_user, name: 'Avery Admin') }
  let(:info_request) { FactoryBot.create(:info_request, user: owner) }
  let(:document) do
    delivered_document(info_request, 'repairs.txt', 'text/plain',
                       "Repairs: 12\nWard: North Lane\n", by: publisher)
  end
  let(:file) { document.foi_attachment }
  let(:manage_path) { disclosure_manage_document_path(document) }
  let(:publish_path) { disclosure_publish_document_path(document) }

  def visitor_state
    reset!
    get disclosure_document_path(document)
    page_status = response.status
    get disclosure_document_download_path(document)
    download_status = response.status
    get disclosure_documents_path, headers: { 'Accept' => 'application/json' }
    listed = JSON.parse(response.body).
      any? { |row| row['id'] == document.public_id }
    { page: page_status, download: download_status, listed: listed }
  end

  def prominence_select
    get edit_admin_foi_attachment_path(file)
    expect(response).to have_http_status(:ok)
    Nokogiri::HTML(response.body).at_css('#foi_attachment_prominence')
  end

  def manage_link
    get edit_admin_foi_attachment_path(file)
    form = Nokogiri::HTML(response.body).
      at_css("form[action='#{admin_foi_attachment_prominence_path(file)}']")
    form.at_css("a[href='#{manage_path}']")
  end

  before do
    sign_in(publisher)
    post publish_path
    expect(response).to redirect_to(manage_path)
    expect(flash[:notice]).
      to eq('Published for the requester. It is now public.')
    @initial_first_published_at = document.reload.first_published_at
  end

  it 'keeps an already-public file blank on the form and refuses blank saves' do
    sign_in(admin)
    select = prominence_select
    expect(select.css('option').map { |opt| opt['value'] }).
      to eq(['', 'requester_only', 'hidden'])
    expect(select.at_css('option[selected]')).to be_nil
    expect(manage_link).to be_present

    patch admin_foi_attachment_prominence_path(file),
          params: { foi_attachment: { prominence: '',
                                      prominence_reason: 'Accidental save' } }

    expect(flash[:error]).to eq('Prominence is not included in the list')
    expect(file.reload.prominence).to eq('public')
    expect(visitor_state).to eq(page: 200, download: 200, listed: true)
  end

  it 'brings a hidden file back by publishing the document, without ' \
     'offering public on the file form', :aggregate_failures do
    sign_in(admin)
    patch admin_foi_attachment_prominence_path(file),
          params: { foi_attachment: { prominence: 'hidden',
                                      prominence_reason: 'Complaint' } }
    expect(flash[:notice]).to eq('Prominence updated.')
    expect(file.reload.prominence).to eq('hidden')
    expect(visitor_state).to eq(page: 410, download: 404, listed: false)

    sign_in(admin)
    select = prominence_select
    expect(select.css('option').map { |opt| opt['value'] }).
      to eq(%w[requester_only hidden])
    expect(select.at_css('option[selected]')['value']).to eq('hidden')
    link = manage_link
    expect(link).to be_present

    patch admin_foi_attachment_prominence_path(file),
          params: { foi_attachment: { prominence: 'public',
                                      prominence_reason: '' } }
    expect(flash[:error]).to eq('Prominence is not included in the list')
    expect(file.reload.prominence).to eq('hidden')
    expect(visitor_state).to eq(page: 410, download: 404, listed: false)

    sign_in(admin)
    document_request(:get, link['href'])
    expect(response).to have_http_status(:ok)
    manage_doc = Nokogiri::HTML(response.body)
    expect(manage_doc.at_css("form[action='#{publish_path}'] button")).
      to be_present

    post publish_path
    expect(response).to redirect_to(manage_path)
    expect(flash[:notice]).
      to eq('Published for the requester. It is now public.')

    document.reload
    expect(file.reload.prominence).to eq('public')
    expect(document.state).to eq('published')
    expect(document.published_by).to eq(admin)
    expect(document.first_published_at).to eq(@initial_first_published_at)
    expect(document.events.where(action: 'published').count).to eq(2)
    expect(visitor_state).to eq(page: 200, download: 200, listed: true)
  end
end
