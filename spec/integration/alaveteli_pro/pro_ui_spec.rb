require 'spec_helper'

RSpec.describe 'Pro navigation', feature: :alaveteli_pro do
  let(:user) { FactoryBot.create(:user) }

  def sign_in_owner
    post '/profile/sign_in', params: {
      user_signin: { email: user.email, password: 'jonespassword' }
    }
  end

  it 'keeps the dashboard out of visitor navigation' do
    get '/help/about'
    expect(Nokogiri::HTML(response.body).css('#dashboard-link')).to be_empty
  end

  it 'keeps disabled projects out of the rendered dashboard' do
    sign_in_owner
    get '/pro/dashboard'
    expect(response).to have_http_status(:ok)
    page = Nokogiri::HTML(response.body)
    expect(page.css('a[href="/pro/projects"]')).to be_empty
    expect(page.css('ul > ul')).to be_empty
    expect(page.at_css('.dashboard-page')).to be_present
  end

  it 'serves the dashboard and request CSS' do
    sign_in_owner
    get '/pro/dashboard'
    css = Nokogiri::HTML(response.body).css('link[rel="stylesheet"]').
      map { |n| n['href'] }.
      find { |href| href.match?(%r{/responsive/application-\h+\.css}) }
    get css
    expect(response).to have_http_status(:ok)
    expect(response.body).
      to include('.dashboard-left-column', '.requests__filter_form')
    expect(response.body).
      to include('max-width:58em').or include('max-width: 58em')
  end
end
