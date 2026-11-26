require 'spec_helper'

# The sign-in journey's pages open with the band every other page has
# (ApplicationHelper#page_band): the title in it, any notice straight after.
RSpec.describe 'The titles of the sign-in pages', type: :request do
  let(:page) { Nokogiri::HTML(response.body) }

  %w[
    /profile/sign_in
    /profile/sign_up
    /profile/sign_out
    /profile/change_password
    /profile/confirmation
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

  # The dialog's frame has no masthead for a band to run on from, and its
  # layout (no_chrome) shows the notice itself.
  it 'keeps a plain title in the sign-in dialog' do
    get '/profile/sign_in', params: { modal: 1 }
    expect(page.css('.page-band')).to be_empty
    expect(page.at_css('h1 + .sign-page')).to be_present
    expect(page.at_css('h1').text).to eq('Sign in')
    expect(page.css('h1').size).to eq(1)
  end
end
