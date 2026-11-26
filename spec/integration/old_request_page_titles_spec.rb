require 'spec_helper'

# The older pages around a request open with the band every other page has
# (ApplicationHelper#page_band).
RSpec.describe 'The titles of the older request pages', type: :request do
  let(:page) { Nokogiri::HTML(response.body) }

  def expect_title_in_band(words)
    expect(response).to have_http_status(:ok)
    expect(page.at_css('body')['class'].split).to include('band-view')
    titles = page.css('#content header.page-band h1.page-band__title')
    expect(titles.map { _1.text.squish }).to eq([words])
    expect(page.css('#content h1').size).to eq(1)
  end

  it 'puts the title of the request form a visitor writes in above the form' do
    body = FactoryBot.create(:public_body)
    get "/new/#{body.url_name}"
    expect_title_in_band('Make a request')
    expect(page.css('#write_form h1')).to be_empty
    expect(page.at_css('header.page-band ~ #write_form')).to be_present
  end

  it 'keeps the link to the request in the title of its event history' do
    owner = FactoryBot.create(:user)
    info_request = FactoryBot.create(:info_request, user: owner)
    sign_in(owner)
    get "/request/#{info_request.url_title}/details"
    expect_title_in_band("Details of request “#{info_request.title}”")
    link = page.at_css('.page-band__title a')
    expect(link['href']).to eq("/request/#{info_request.url_title}")
  end
end
