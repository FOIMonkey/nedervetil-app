require 'spec_helper'

RSpec.describe 'Security headers', type: :request do
  include_context 'with production error pages'

  let(:user) { FactoryBot.create(:user) }

  # Include disabled headers in the slice so eq(standard) proves their absence.
  def security_headers
    sent_headers.slice(
      'x-frame-options', 'x-content-type-options',
      'x-permitted-cross-domain-policies', 'referrer-policy',
      'strict-transport-security', 'x-xss-protection', 'x-download-options'
    )
  end

  let(:standard) do
    { 'x-frame-options' => 'sameorigin',
      'x-content-type-options' => 'nosniff',
      'x-permitted-cross-domain-policies' => 'none',
      'referrer-policy' => 'strict-origin-when-cross-origin' }
  end

  it 'go out with a page' do
    get '/help/about'

    expect(response).to have_http_status(:ok)
    expect(security_headers).to eq(standard)
  end

  it 'go out with a page that is not found' do
    get '/no/such/page'

    expect(response).to have_http_status(:not_found)
    expect(security_headers).to eq(standard)
  end

  it 'go out with a redirect' do
    get '/pro/info_requests'

    expect(response).to have_http_status(:found)
    expect(security_headers).to eq(standard)
  end

  it 'name only the site, never the page, in a referrer from a sign-in page' do
    get '/profile/sign_in'

    expect(response).to have_http_status(:ok)
    expect(security_headers).
      to eq(standard.merge('referrer-policy' => 'strict-origin'))
  end

  it 'leave the content security policy to Rails, which sends one' do
    get '/help/about'

    expect(page_policy).to eq(
      "default-src 'self' https:; font-src 'self' https: data:; " \
      "img-src 'self' https: data:; object-src 'none'; base-uri 'self'; " \
      "form-action 'self'; script-src 'self' 'strict-dynamic' 'nonce'; " \
      "style-src 'self' https: 'unsafe-inline'"
    )
  end

  describe 'the session cookie' do
    it 'is kept from scripts and from requests other sites start' do
      sign_in(user)

      expect(cookies_set.size).to eq(1)
      expect(cookies_set.first).to start_with('_wdtk_cookie_session=')
      expect(cookie_attributes(cookies_set.first)).
        to eq(%w[path=/ httponly samesite=lax])
    end

    it 'is also kept to HTTPS when the request came over HTTPS' do
      https!
      post '/profile/sign_in',
           params: { user_signin: { email: user.email,
                                    password: 'jonespassword' } },
           headers: { 'Origin' => "https://#{host}" }

      expect(cookies_set.size).to eq(1)
      expect(cookie_attributes(cookies_set.first)).
        to eq(%w[path=/ httponly samesite=lax secure])
    end

    it 'keeps the same flags when it is being forgotten' do
      # Consuming the flash triggers StripEmptySessions to expire the cookie.
      post '/help/contact',
           params: { contact: { name: 'Vinny Vanilli',
                                email: 'vinny@localhost',
                                subject: 'A question',
                                message: 'Where do I start?' },
                     submitted_contact_form: 1 },
           headers: { 'Origin' => "http://#{host}" }
      follow_redirect!

      expect(cookies_set.size).to eq(1)
      expect(cookies_set.first).to start_with('_wdtk_cookie_session=;')
      expect(cookie_attributes(cookies_set.first)).to eq(
        ['path=/', 'max-age=0', 'expires=thu, 01 jan 1970 00:00:00 gmt',
         'httponly', 'samesite=lax']
      )
    end
  end
end
