require 'spec_helper'

# The signed-in pages for working on requests and documents open with the
# band every other page has (ApplicationHelper#page_band). Those that had a
# link back above their title have it in the band.
RSpec.describe 'The titles of the tool pages', type: :request do
  let(:owner) { FactoryBot.create(:user) }
  let(:info_request) { FactoryBot.create(:info_request, user: owner) }
  let(:page) { Nokogiri::HTML(response.body) }

  before { sign_in(owner) }

  def expect_title_in_band(words)
    expect(response).to have_http_status(:ok)
    expect(page.at_css('body')['class'].split).to include('band-view')
    titles = page.css('#content header.page-band h1.page-band__title')
    expect(titles.map { _1.text.squish }).to eq([words])
    expect(page.css('#content h1').size).to eq(1)
  end

  def way_back
    page.at_css('.page-band .page-band__back a')
  end

  it 'gives your documents the way back to all documents, in the band' do
    get '/documents/yours'
    expect_title_in_band('Your documents')
    expect(way_back.text).to eq('All documents')
    expect(way_back['href']).to eq('/documents')
    expect(page.css('.document__back')).to be_empty
  end

  it 'gives deleting a request\'s emails the way back to the request' do
    get "/request/#{info_request.url_title}/delete"
    expect_title_in_band('Delete the emails, keep the documents')
    expect(way_back['href']).to eq("/request/#{info_request.url_title}")
  end

  it 'puts the title of the report form in the band' do
    get "/request/#{info_request.url_title}/report/new"
    expect(response).to have_http_status(:ok)
    expect(page.css('#content header.page-band h1.page-band__title').size).
      to eq(1)
    expect(page.css('#content h1').size).to eq(1)
  end

  it 'puts the title of choosing a batch\'s authorities in the band' do
    get '/pro/batch_request_authority_searches'
    expect_title_in_band('Add authorities to your batch')
    expect(page.css('.inner-canvas-header')).to be_empty
  end
end
