require 'spec_helper'

# The account's settings pages open with the band every other page has
# (ApplicationHelper#page_band), and those reached from the account page
# have the way back to it in the band.
RSpec.describe 'The titles of the account pages', type: :request do
  let(:user) { FactoryBot.create(:user) }
  let(:page) { Nokogiri::HTML(response.body) }

  before do
    allow(AlaveteliConfiguration).
      to receive(:enable_two_factor_auth).and_return(true)
    sign_in(user)
  end

  def expect_title_in_band
    expect(response).to have_http_status(:ok)
    expect(page.at_css('body')['class'].split).to include('band-view')
    expect(page.css('#content header.page-band h1.page-band__title').size).
      to eq(1)
    expect(page.css('#content h1').size).to eq(1)
  end

  %w[
    /profile/two_factor
    /profile/change_email
    /profile/name/edit
    /profile/ai_reading
    /profile/emails
  ].each do |path|
    it "puts the title of #{path} in the band, under the way back" do
      get path
      expect_title_in_band
      back = page.at_css('.page-band .page-band__back a')
      expect(back.text).to eq('Account')
      expect(back['href']).to eq("/user/#{user.url_name}")
      expect(page.css("#content a[href='/user/#{user.url_name}']").size).
        to eq(1)
    end
  end

  it 'puts the title of the first step of setting up two factor in the ' \
     'band, with no way back' do
    get '/profile/two_factor/new'
    expect_title_in_band
    expect(page.css('.page-band__back')).to be_empty
  end
end
