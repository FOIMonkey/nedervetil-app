require 'spec_helper'

RSpec.describe 'The titles of the error pages', type: :request do
  include_context 'consider all requests remote'

  let(:page) { Nokogiri::HTML(response.body) }

  def expect_title_in_band(words)
    expect(page.at_css('body')['class'].split).to include('band-view')
    titles = page.css('#content header.page-band h1.page-band__title')
    expect(titles.map(&:text)).to eq([words])
    expect(page.css('#content h1').size).to eq(1)
  end

  it 'says in the band that a page could not be found' do
    get '/frobsnasm'
    expect(response).to have_http_status(:not_found)
    expect_title_in_band("Sorry, we couldn't find that page")
    expect(page.css('#error-page h1')).to be_empty
  end

  it 'says in the band that there was a problem' do
    allow(InfoRequest).to receive(:find_by_url_title!).
      and_raise('An example error')
    get '/request/example'
    expect(response).to have_http_status(:internal_server_error)
    expect_title_in_band('Sorry, there was a problem processing this page')
  end

  it 'says in the band that a form could not be sent' do
    post change_request_path
    expect(response).to have_http_status(:bad_request)
    expect_title_in_band("This form couldn't be sent")
  end

  # The sign-in modal uses layouts/no_chrome, which has no page band.
  context 'when a form in the sign-in dialog is sent from another site' do
    around do |example|
      original = ActionController::Base.allow_forgery_protection
      ActionController::Base.allow_forgery_protection = true
      example.run
    ensure
      ActionController::Base.allow_forgery_protection = original
    end

    def send_sign_in(params)
      post signin_path,
           params: params.merge(user_signin: { email: 'a@example.com',
                                               password: 'not it' }),
           headers: { 'Origin' => 'null' }
    end

    it 'gives the refusal a plain title and no band' do
      send_sign_in(modal: 1)
      expect(response).to have_http_status(422)
      expect(page.css('.page-band')).to be_empty
      expect(page.css('h1').map(&:text)).to eq(["This form couldn't be sent"])
    end

    it 'gives the same refusal its band on a page of its own' do
      send_sign_in({})
      expect(response).to have_http_status(422)
      expect_title_in_band("This form couldn't be sent")
    end
  end

  it 'gives an emailed link that does not work a short title' do
    get '/c/not-a-token'
    expect(response).to have_http_status(:not_found)
    expect_title_in_band('Check the link in your email')
    expect(page.at_css('title').text).to include('Check the link in your email')
    expect(page.at_css('#content p').text).to include('Please check the URL')
  end
end
