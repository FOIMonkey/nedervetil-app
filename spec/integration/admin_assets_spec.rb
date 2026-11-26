require 'spec_helper'

RSpec.describe 'Admin assets' do
  include ActiveJob::TestHelper
  include DisclosuresHelpers
  include_context 'with document OCR off'

  let(:owner) { FactoryBot.create(:user) }
  let(:admin) { FactoryBot.create(:admin_user) }
  let(:body) { FactoryBot.create(:public_body) }
  let(:info_request) do
    FactoryBot.create(:info_request, user: owner, public_body: body)
  end

  def page = Nokogiri::HTML(response.body)

  def assets
    page.css('script[src], link[rel="stylesheet"]').
      map { _1['src'] || _1['href'] }
  end

  before { sign_in(admin) }

  it 'loads nothing of Bootstrap on admin and public pages' do
    ['/admin', '/help/about'].each do |path|
      get path
      expect(assets).
        to include(a_string_matching(%r{/assets/admin(-\h+)?\.css}))
      expect(assets.grep(/bootstrap/)).to eq([])
    end
  end

  it 'serves admin assets with no Bootstrap code in them' do
    get '/admin'
    assets.grep(%r{/assets/admin(-\h+)?\.(js|css)}).each do |asset|
      get asset
      expect(response).to have_http_status(:ok)
      expect(response.body).not_to match(
        /bootstrap|twipsy|glyphicons|\.popover|\.tooltip\(|\.tab\(/i
      )
    end
  end

  it 'serves Trix from the site, with a nonce' do
    get '/admin'
    expect(assets.grep(/unpkg/)).to eq([])
    trix = page.at_css('script[src*="/assets/trix"]')
    expect(trix['nonce']).to be_present

    get trix['src']
    expect(response).to have_http_status(:ok)
    expect(response.body).to start_with("/*\nTrix #{Trix::VERSION}\n")
    expect(response.body).to include('DOMPurify 3.4.18')
    expect(response.body).not_to include('DOMPurify 3.4.2 ')
  end

  it 'runs the admin on the admin importmap alone' do
    get '/admin'
    expect(page.at_css('script[type="importmap"]')).to be_present
    expect(page.at_css('body.admin')['data-controller'].split).
      to include('confirm', 'method-link', 'form-lock', 'admin-jump')
    expect(page.at_css('body.admin')['data-controller'].split).
      not_to include('toggles')
    expect(assets.grep(%r{/assets/admin(-\h+)?\.js})).to eq([])
    expect(response.body).not_to match(/jquery/i)
  end

  it 'leaves no legacy data-toggle attributes on admin pages' do
    delivered_document(info_request, 'runs.txt', 'text/plain', "North: 12\n",
                       by: owner, ready: false)
    %W[
      /admin
      /admin/requests/#{info_request.id}
      /admin/users/#{owner.id}
      /admin/bodies/#{body.id}/edit
    ].each do |path|
      get path
      expect(page.css('[data-toggle]')).to be_empty, path
    end
  end
end
