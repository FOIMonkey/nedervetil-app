require 'spec_helper'

RSpec.describe 'Signing in with a bounded return', local_requests: false do
  include_context 'with production error pages'
  let(:user) { FactoryBot.create(:user) }

  def submit_sign_in_form
    destination = Nokogiri::HTML(response.body).
      at_css('#signin_form input[name="r"]')['value']
    post signin_path, params: {
      r: destination,
      user_signin: { email: user.email, password: 'jonespassword' }
    }, headers: { 'Origin' => "http://#{host}" }
  end

  it 'opens a private request belonging to the authenticated account' do
    request = FactoryBot.create(:info_request, user: user)
    get signin_path, params: { r: show_request_path(request.url_title) }
    submit_sign_in_form
    expect(response).to redirect_to(show_request_path(request.url_title))
    follow_redirect!
    expect(response).to have_http_status(:ok)
  end

  it 'still enforces ownership at the returned page' do
    request = FactoryBot.create(:info_request)
    get signin_path, params: { r: show_request_path(request.url_title) }
    submit_sign_in_form
    follow_redirect!
    expect(response).to have_http_status(:not_found)
  end

  it 'uses the safe default for an external or admin destination' do
    ['https://example.invalid/malicious', '//example.invalid',
     '/admin/users'].each do |path|
      get signin_path, params: { r: path }
      submit_sign_in_form
      expect(response).to redirect_to(Authentication::ReturnPath::DEFAULT)
    end
  end

  it 'consumes the destination once after full authentication' do
    get signin_path, params: { r: help_about_path }
    submit_sign_in_form
    expect(response).to redirect_to(help_about_path)
    post signout_path
    sign_in(user)
    expect(response).to redirect_to(Authentication::ReturnPath::DEFAULT)
  end
end
