require 'spec_helper'

RSpec.describe 'Sign in page' do
  def page
    Nokogiri::HTML(response.body)
  end

  # Where the link with this text goes: its path, and what it carries.
  def target_of(text)
    link = page.css('#content a').find { |a| a.text == text }
    return unless link

    uri = URI(link['href'])
    [uri.path, Rack::Utils.parse_query(uri.query)]
  end

  it 'shows the sign in form alone, under its own heading' do
    get '/profile/sign_in'

    expect(response).to have_http_status(:ok)
    expect(page.css('#content h1').map(&:text)).to eq(['Sign in'])
    expect(response.body).to include('user_signin[email]')
    expect(response.body).not_to include('user_signup[')
  end

  it 'links to the sign up page' do
    get '/profile/sign_in'

    expect(page.at_css('#content').text).to include('New here?')
    expect(target_of('Create an account')).to eq(['/profile/sign_up', {}])
  end

  it 'hands the sign up page where the visitor was going, and the dialog' do
    get '/profile/sign_in', params: { r: '/help/about', modal: 1 }

    expect(target_of('Create an account')).
      to eq(['/profile/sign_up', { 'r' => '/help/about', 'modal' => '1' }])
  end

  it 'never hands on a return path to somewhere else' do
    get '/profile/sign_in', params: { r: 'https://elsewhere.example/' }

    expect(target_of('Create an account')).
      to eq(['/profile/sign_up',
             { 'r' => Authentication::ReturnPath::DEFAULT }])
  end

  it 'shows its own form again, with a message, when signing in fails' do
    post '/profile/sign_in',
         params: { r: '/help/about',
                   user_signin: { email: 'nobody@localhost',
                                  password: 'not-a-password' } },
         headers: { 'Origin' => "http://#{host}" }

    expect(response).to have_http_status(422)
    expect(page.css('#content h1').map(&:text)).to eq(['Sign in'])
    expect(response.body).to include('was not recognised')
    expect(response.body).to include('user_signin[email]')
    expect(response.body).not_to include('user_signup[')
    expect(target_of('Create an account')).
      to eq(['/profile/sign_up', { 'r' => '/help/about' }])
  end

  it 'has no site header in the dialog' do
    get '/profile/sign_in', params: { modal: 1 }

    expect(page.at_css('#signin_form')).to be_present
    expect(page.at_css('#banner')).to be_nil
  end

  context 'when sign-ups are a read-only feature' do
    before do
      allow(AlaveteliConfiguration).
        to receive(:read_only_features).and_return(['signups'])
    end

    it 'says so in place of the link to the sign up page' do
      get '/profile/sign_in'

      expect(page.at_css('#content').text).
        to include('Sign-ups for new accounts are closed.')
      expect(page.at_css('#content').text).not_to include('New here?')
      expect(target_of('Create an account')).to be_nil
      expect(response.body).to include('user_signin[email]')
      expect(response.body).not_to include('user_signup[')
    end

    it 'does not create an account when the sign up form is posted anyway' do
      expect {
        post '/profile/sign_up', params: {
          user_signup: { name: 'New Person',
                         email: 'new.person@localhost' }
        }
      }.not_to(change { User.count })

      expect(response).to redirect_to('/')
    end
  end

  context 'when the whole site is read-only' do
    before do
      allow(AlaveteliConfiguration).
        to receive(:read_only).and_return('Down for maintenance')
    end

    it 'offers no new account' do
      get '/profile/sign_in'

      expect(target_of('Create an account')).to be_nil
      expect(response.body).to include('user_signin[email]')
      expect(response.body).not_to include('user_signup[')
    end
  end
end
