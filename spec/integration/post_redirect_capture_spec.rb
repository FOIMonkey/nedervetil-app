require 'spec_helper'

# Regression contracts from #220/#221, now backed by the replacement storage.
RSpec.describe 'Retired replay and bounded authentication returns',
  type: :request do
  include_context 'consider all requests remote'
  let(:user) { FactoryBot.create(:user) }
  let(:origin) { { 'Origin' => "http://#{host}" } }
  let(:legacy) do
    PostRedirect.create!(
      uri: '/profile/change_email',
      token: 'invented-legacy-token',
      email_token: 'invented-legacy-email',
      post_params_yaml: {
        'signchangeemail' => {
          'password' => 'invented-secret',
          'new_email' => 'replay@example.test'
        }
      }.to_yaml,
      reason_params_yaml: {}.to_yaml,
      user: user
    )
  end

  it 'does not create any replay or return record for a plain sign-in GET' do
    expect { get signin_path }.not_to change(PostRedirect, :count)
    expect { get signin_path }.not_to change(AuthenticationReturn, :count)
    expect(response).to have_http_status(:ok)
  end

  it 'carries a normalized return in the form without storing a row or cookie' do
    ['/help/about', '/help/about?email_token=discard'].each do |destination|
      expect do
        get signin_path(r: destination)
      end.not_to change(AuthenticationReturn, :count)
      expect(PostRedirect.count).to eq(0)
      expect(response).to have_http_status(:ok)
      expect(response.headers['Set-Cookie']).to be_nil
      field = Nokogiri::HTML(response.body).
        at_css('#signin_form input[name="r"]')
      expect(field['value']).to eq('/help/about')
    end
  end

  it 'keeps repeated anonymous gated-page GETs free of rows and cookies' do
    3.times do
      [signchangeemail_path, new_one_time_password_path,
       one_time_password_backup_codes_path].each do |path|
        expect { get path }.not_to change(AuthenticationReturn, :count)
        expect(response.headers['Set-Cookie']).to be_nil
        expect(response).to redirect_to(signin_path(r: path))
        follow_redirect!
        expect(response.headers['Set-Cookie']).to be_nil
        expect(Nokogiri::HTML(response.body).
          at_css('#signin_form input[name="r"]')['value']).to eq(path)
      end
    end
    expect(PostRedirect.count).to eq(0)
    expect(AuthenticationReturn.count).to eq(0)
  end

  it 'returns to a gated page only after complete authentication' do
    get signchangeemail_path
    follow_redirect!
    target = Nokogiri::HTML(response.body).
      at_css('#signin_form input[name="r"]')['value']
    expect(AuthenticationReturn.count).to eq(0)
    post signin_path, params: {
      r: target, user_signin: { email: user.email, password: 'jonespassword' }
    }, headers: origin
    expect(response).to redirect_to(signchangeemail_path)
    expect(AuthenticationReturn.last.consumed_at).to be_present
  end

  it 'does not store a submitted return until the required factors succeed' do
    user.update!(otp_required_for_login: true,
                 otp_secret: User.generate_otp_secret)
    credentials = { email: user.email, password: 'wrong-password' }
    expect do
      post signin_path, params: { r: '/help/about', user_signin: credentials },
                        headers: origin
    end.not_to change(AuthenticationReturn, :count)
    expect(response).to have_http_status(422)
    field = Nokogiri::HTML(response.body).at_css('#signin_form input[name="r"]')
    credentials[:password] = 'jonespassword'
    expect do
      post signin_path, params: { r: field['value'], user_signin: credentials },
                        headers: origin
    end.not_to change(AuthenticationReturn, :count)
    expect(request.env['warden'].user(scope: :user)).to be_nil
    credentials[:otp_attempt] = user.current_otp
    post signin_path, params: { r: field['value'], user_signin: credentials },
                      headers: origin
    expect(response).to redirect_to('/help/about')
    expect(AuthenticationReturn.last.consumed_at).to be_present
  end

  it 'holds the return through restricted enrolment until the new OTP succeeds' do
    user.update!(otp_required_for_login: true)
    get signin_path(r: '/help/about')
    target = Nokogiri::HTML(response.body).
      at_css('#signin_form input[name="r"]')['value']
    expect(AuthenticationReturn.count).to eq(0)
    post signin_path, params: {
      r: target, user_signin: { email: user.email, password: 'jonespassword' }
    }, headers: origin
    expect(response).to redirect_to(new_one_time_password_path)
    saved = AuthenticationReturn.last
    expect(saved.user).to eq(user)
    expect(saved.consumed_at).to be_nil
    expect(request.env['warden'].user(scope: :user)).to be_nil
    challenge = AuthenticationEnrolment.last
    post one_time_password_path, params: {
      otp_code: ROTP::TOTP.new(challenge.secret).now
    }, headers: origin
    expect(response).to have_http_status(:ok)
    expect(saved.reload.consumed_at).to be_present
    expect(Nokogiri::HTML(response.body).
      at_css('a[target="_top"]')['href']).to eq('/help/about')
  end

  it 'never merges or consumes old saved parameters' do
    legacy
    get signchangeemail_path(post_redirect: '1', token: legacy.token)
    expect(response).to redirect_to(signin_path(r: signchangeemail_path))
    sign_in(user)
    follow_redirect!
    expect(user.reload.email).not_to eq('replay@example.test')
    expect(PendingEmailChange.count).to eq(0)
    expect(PostRedirect.exists?(legacy.id)).to be true
    expect(response.body).not_to include('invented-secret')
  end

  it 'does not exchange an old confirmation token for confirmation or a session' do
    get confirm_path(email_token: legacy.email_token)
    expect(response).to have_http_status(:not_found)
    post confirm_path(email_token: legacy.email_token), headers: origin
    expect(response).to have_http_status(:not_found)
    expect(request.env['warden'].user(scope: :user)).to be_nil
  end

  it 'does not exchange an old reset token for new credentials or a session' do
    patch password_change_path(reset_password_token: legacy.email_token),
          params: {
            password_change_user: {
              password: 'invented-new-password',
              password_confirmation: 'invented-new-password'
            }
          },
          headers: origin
    expect(response).to have_http_status(422)
    expect(user.reload.valid_password?('jonespassword')).to be true
    expect(request.env['warden'].user(scope: :user)).to be_nil
  end

  it 'returns once to the allowed page after complete modal authentication' do
    get signin_path(
      r: '/profile/name/edit?password=discard&email_token=discard', modal: 1
    )
    post signin_path,
      params: { modal: 1, r: Nokogiri::HTML(response.body).
        at_css('#signin_form input[name="r"]')['value'],
                user_signin: { email: user.email,
                               password: 'jonespassword' } }, headers: origin
    expect(response).to have_http_status(:ok)
    expect(response.body).
      to include('data-signin-success-return-value="/profile/name/edit"')
    expect(AuthenticationReturn.last.path).to eq('/profile/name/edit')
    expect(AuthenticationReturn.last.consumed_at).to be_present
    expect(response.body).not_to include('discard')
  end

  it 'never preserves credentials from expired email, recovery or enrolment forms' do
    [signchangeemail_path, one_time_password_path,
     one_time_password_backup_codes_path].each do |path|
      post path,
        params: { password: 'invented-secret', otp_code: 'invented-code',
                  signchangeemail: { password: 'invented-secret',
                                     otp_attempt: 'invented-code',
                                     new_email: 'new@example.test' } },
        headers: origin
    end
    expect(PostRedirect.count).to eq(0)
    expect(PendingRequestDraft.count).to eq(0)
    AuthenticationReturn.find_each do |record|
      expect(record.path).not_to match(/invented-secret|invented-code|new%40/)
    end
  end

  it 'rejects the old two-factor challenge endpoint and admin impersonation routes' do
    post '/profile/sign_in/two_factor', params: { code: '123456' },
                                        headers: origin
    expect(response).to have_http_status(:not_found)
    admin = FactoryBot.create(:admin_user)
    sign_in(admin)
    ["/admin/users/#{user.id}/sessions", "/admin/users_sessions"].each do |path|
      post path, headers: origin
      expect(response).to have_http_status(:not_found)
    end
    expect(request.env['warden'].user(scope: :user).id).to eq(admin.id)
  end
end
