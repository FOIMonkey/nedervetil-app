require 'spec_helper'

RSpec.describe 'Sign up page' do
  let(:origin) { { 'Origin' => "http://#{host}" } }

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

  it 'shows the sign up form alone, under its own heading' do
    get '/profile/sign_up'

    expect(response).to have_http_status(:ok)
    expect(page.css('#content h1').map(&:text)).to eq(['Create an account'])
    expect(response.body).to include('user_signup[email]')
    expect(response.body).not_to include('user_signin[')
  end

  it 'links to the sign in page' do
    get '/profile/sign_up'

    expect(page.at_css('#content').text).to include('Already have an account?')
    expect(target_of('Sign in')).to eq(['/profile/sign_in', {}])
  end

  it 'hands the sign in page where the visitor was going, and the dialog' do
    get '/profile/sign_up', params: { r: '/help/about', modal: 1 }

    expect(target_of('Sign in')).
      to eq(['/profile/sign_in', { 'r' => '/help/about', 'modal' => '1' }])
    expect(page.at_css('#signup_form input[name="r"]')['value']).
      to eq('/help/about')
    expect(page.at_css('#signup_form input[name="modal"]')['value']).to eq('1')
  end

  it 'sets no cookie and keeps nothing for a visitor who only looks' do
    expect { get '/profile/sign_up', params: { r: '/help/about' } }.
      not_to(change { [User.count, AuthenticationReturn.count] })

    expect(response).to have_http_status(:ok)
    expect(response.headers['Set-Cookie']).to be_nil
  end

  it 'has no site header in the dialog' do
    get '/profile/sign_up', params: { modal: 1 }

    expect(page.at_css('#signup_form')).to be_present
    expect(page.at_css('#banner')).to be_nil
  end

  it 'shows its own form again, with what was typed, when it is invalid' do
    expect {
      post '/profile/sign_up',
           params: { r: '/help/about', modal: 1,
                     user_signup: { name: 'New Person',
                                    email: 'not an address' } },
           headers: origin
    }.not_to(change { User.count })

    expect(response).to have_http_status(422)
    expect(page.css('#content h1').map(&:text)).to eq(['Create an account'])
    expect(page.at_css('#user_signup_name')['value']).to eq('New Person')
    expect(page.at_css('#user_signup_email')['value']).
      to eq('not an address')
    expect(response.body).not_to include('user_signin[')
    expect(page.at_css('#banner')).to be_nil
    expect(target_of('Sign in')).
      to eq(['/profile/sign_in', { 'r' => '/help/about', 'modal' => '1' }])
  end

  it 'stays in the dialog on the page that says to check your email' do
    expect {
      post '/profile/sign_up',
           params: { modal: 1,
                     user_signup: {
                       name: 'New Person',
                       email: 'new.person@localhost'
                     } },
           headers: origin
    }.to change { User.count }.by(1)

    expect(response).to have_http_status(:ok)
    expect(page.at_css('#content h1').text).to eq('Check your email')
    expect(page.at_css('#banner')).to be_nil
    expect(target_of('Sign in')).to eq(['/profile/sign_in', { 'modal' => '1' }])
  end

  # Devise's own answer is a redirect through after_sign_in_path_for, which
  # would use up a saved letter or return path.
  it 'shows the page to someone already signed in, as the sign in page does' do
    sign_in(FactoryBot.create(:user))

    ['/profile/sign_in', '/profile/sign_up'].each do |path|
      get path
      expect(response).to have_http_status(:ok), path
    end
    expect(response.body).to include('user_signup[email]')
  end

  context 'when sign-ups are a read-only feature' do
    before do
      allow(AlaveteliConfiguration).
        to receive(:read_only_features).and_return(['signups'])
    end

    it 'sends the visitor to the sign in page' do
      get '/profile/sign_up'

      expect(response).to redirect_to('/profile/sign_in')
      expect(response.headers['Set-Cookie']).to be_nil
    end

    it 'keeps where the visitor was going, and the dialog' do
      get '/profile/sign_up', params: { r: '/help/about', modal: 1 }

      expect(response).
        to redirect_to('/profile/sign_in?modal=1&r=%2Fhelp%2Fabout')
    end
  end

  context 'when the whole site is read-only' do
    before do
      allow(AlaveteliConfiguration).
        to receive(:read_only).and_return('Down for maintenance')
    end

    it 'sends the visitor to the sign in page' do
      get '/profile/sign_up'

      expect(response).to redirect_to('/profile/sign_in')
    end
  end
end
