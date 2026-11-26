require 'spec_helper'

RSpec.describe 'Where a form may be sent from', type: :request do
  around do |example|
    ActionController::Base.allow_forgery_protection = true
    example.run
  ensure
    ActionController::Base.allow_forgery_protection = false
  end

  let(:here) { 'http://www.example.com' }
  let(:elsewhere) { 'https://elsewhere.example' }

  let(:forms) do
    {
      'sign in' => ['/profile/sign_in',
                    { user_signin: { email: 'a@example.com',
                                     password: 'wrong' } }],
      'sign up' => ['/profile/sign_up',
                    { user_signup: { email: 'new@example.com',
                                     name: 'New Person' } }],
      'contact' => ['/help/contact',
                    { contact: { name: 'A', email: 'a@example.com',
                                 subject: 'Hello', message: 'Hi',
                                 comment: '' },
                      submitted_contact_form: 1 }],
      'change request' => ['/change_request',
                           { public_body_change_request: {
                             user_name: 'A', user_email: 'a@example.com',
                             public_body_name: 'New Body', notes: 'Please',
                             comment: ''
                           } }],
      'password reset' => ['/profile/change_password',
                           { password_change_user: {
                             email: 'a@example.com'
                           } }]
    }
  end

  def send_form(name, headers = {})
    path, params = forms.fetch(name)
    post path, params: params, headers: headers
  end

  it 'refuses each signed-out form sent from another site' do
    forms.each_key do |name|
      send_form(name, 'Origin' => elsewhere)
      expect(response).to have_http_status(422), name
      expect(response.body).to include("This form couldn't be sent"), name
    end
  end

  it 'accepts each signed-out form sent from this site' do
    forms.each_key do |name|
      send_form(name, 'Origin' => here)
      # A wrong password answers 422 too, so look for the refusal itself.
      expect(response.body).not_to include("This form couldn't be sent"), name
    end
  end

  it 'judges by the Referer when there is no Origin' do
    send_form('contact', 'Referer' => "#{elsewhere}/page")
    expect(response).to have_http_status(422)
    send_form('contact', 'Referer' => "#{here}/help/contact")
    expect(response).to redirect_to(frontpage_url)
  end

  it 'refuses the "null" Origin a page can make its browser send' do
    send_form('contact', 'Origin' => 'null')
    expect(response).to have_http_status(422)
  end

  it 'refuses a request with neither, as every browser sends Origin' do
    send_form('contact')
    expect(response).to have_http_status(422)
  end

  it 'sets no cookie on a page a signed-out visitor reads, form or not' do
    get '/help/contact'
    expect(response).to be_successful
    expect(response.headers['Set-Cookie'].to_s).
      not_to include('_wdtk_cookie_session')
  end

  it 'accepts a signed-in admin’s form with its token, without an Origin' do
    with_setting(ActionController::Base, :per_form_csrf_tokens, true) do
      admin = FactoryBot.create(:admin_user)
      sign_in(admin)
      get '/admin/announcements/new'
      form = Nokogiri::HTML(response.body).
        at_css("form[action='/admin/announcements']")
      post '/admin/announcements',
           params: { authenticity_token:
                       form.at_css('[name=authenticity_token]')['value'],
                     announcement: { visibility: 'everyone',
                                     title: 'Notice', content: 'Hello' } }
      expect(response).not_to have_http_status(422)
      expect(Announcement.where(title: 'Notice')).to exist
    end
  end

  it 'still wants the token from someone signed in' do
    user = FactoryBot.create(:user)
    post '/profile/sign_in',
         params: { user_signin: { email: user.email,
                                  password: 'jonespassword' } },
         headers: { 'Origin' => here }
    post '/help/contact', params: forms.dig('contact', 1),
                          headers: { 'Origin' => here }
    expect(response).to have_http_status(422)
  end
end
