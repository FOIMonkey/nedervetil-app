require 'spec_helper'

# The older request and help pages open with the band every other page has
# (ApplicationHelper#page_band).
RSpec.describe 'The titles of the older request and help pages',
               type: :request do
  let(:page) { Nokogiri::HTML(response.body) }

  %w[
    /select_authority
    /body/list/all
    /change_request/new
    /help/api
    /help/unhappy
  ].each do |path|
    it "puts the title of #{path} in the band" do
      get path
      expect(response).to have_http_status(:ok)
      expect(page.at_css('body')['class'].split).to include('band-view')
      expect(page.css('#content header.page-band h1.page-band__title').size).
        to eq(1)
      expect(page.css('#content h1').size).to eq(1)
    end
  end

  it 'gives the A to Z list its way back to the authorities' do
    get '/body/list/all'
    back = page.at_css('.page-band .page-band__back a')
    expect(back.text).to eq('Authorities')
    expect(back['href']).to eq('/groups')
  end

  # The page's words sit under the band, not beside it. (The side column is
  # a theme's: core's own is a placeholder.)
  it 'puts the band before the column of a help page' do
    get '/help/api'
    parts = page.css('#help_api > *').map { _1['id'] || _1['class'] }
    expect(parts).to eq(%w[page-band left_column_flip])
  end
end
