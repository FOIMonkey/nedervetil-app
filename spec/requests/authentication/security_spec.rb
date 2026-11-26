require 'spec_helper'

RSpec.describe 'Authentication policy regressions', type: :request do
  include_context 'consider all requests remote'
  around do |example|
    original = ActionController::Base.allow_forgery_protection
    example.run
  ensure
    ActionController::Base.allow_forgery_protection = original
  end

  let(:password) { 'invented-owner-password' }
  let(:user) { FactoryBot.create(:user, password: password) }
  let(:origin) { { 'Origin' => "http://#{host}" } }

  def login(code: nil, email: user.email, password_value: password)
    post signin_path,
      params: { user_signin: { email: email, password: password_value,
                               otp_attempt: code } }, headers: origin
  end

  def enrol
    user.update!(otp_secret: User.generate_otp_secret,
                 otp_required_for_login: true)
    codes = user.generate_otp_backup_codes!
    user.save!
    codes
  end

  def reset_password(token, value = 'changed-invented-password',
                     confirmation: value, code: nil, headers: origin)
    patch password_change_path(id: token), params: { password_change_user: {
      password: value, password_confirmation: confirmation, otp_attempt: code
    } }, headers: headers
  end

  it 'requires migrated ordinary owners to re-enrol after resetting credentials' do
    user.update_columns(encrypted_password: '',
                        credential_reset_required: true,
                        otp_required_for_login: true)
    token = user.send_reset_password_instructions
    reset_password(token)
    expect(user.reload.credential_reset_required?).to be false
    login(password_value: 'changed-invented-password')
    expect(response).to redirect_to(new_one_time_password_path)
    expect(request.env['warden'].user(scope: :user)).to be_nil
    get show_user_profile_path(user.url_name)
    expect(response).to have_http_status(:not_found)
    challenge = AuthenticationEnrolment.last
    post one_time_password_path,
      params: { otp_code: ROTP::TOTP.new(challenge.secret).now },
      headers: origin
    expect(response).to have_http_status(:ok)
    expect(user.reload.totp?).to be true
    get show_user_profile_path(user.url_name)
    expect(response).to have_http_status(:ok)
  end

  it 'can resend confirmation while signup is closed without signing in' do
    account = FactoryBot.create(:unconfirmed_user, password: password)
    ActionMailer::Base.deliveries.clear
    allow(AlaveteliConfiguration).to receive(:read_only_features).
      and_return(['signups'])
    post user_confirmation_path, params: { user: { email: account.email } },
                                 headers: origin
    expect(response).to have_http_status(:ok)
    expect(ActionMailer::Base.deliveries.map(&:to)).to eq([[account.email]])
    expect(account.reload.confirmed?).to be false
    expect(request.env['warden'].user(scope: :user)).to be_nil
    expect(PendingRequestDraft.count).to eq(0)
  end

  it 'does not run credential strategies on private pages or the Sidekiq mount' do
    user.add_role(:admin)
    enrol
    credentials = { email: user.email, password: password,
                    otp_attempt: user.current_otp }
    [show_user_profile_path(user.url_name), '/sidekiq'].each do |path|
      get path, params: { user: credentials }, headers: {
        'Authorization' => ActionController::HttpAuthentication::Basic.
          encode_credentials(user.email, password)
      }
      expect(response).to have_http_status(:not_found)
      expect(request.env['warden'].user(scope: :user)).to be_nil
    end
    expect(user.reload.consumed_timestep).to be_nil
  end

  it 'opens the mailed reset URL and requires an admin’s second factor' do
    ActionController::Base.allow_forgery_protection = true
    user.add_role(:admin)
    codes = enrol
    original_secret = user.otp_secret
    token = user.send_reset_password_instructions
    url = URI(ActionMailer::Base.deliveries.last.body.decoded.
      match(%r{https?://[^\s<]+/profile/change_password/[^\s<]+})[0])
    get url.path
    expect(response).to have_http_status(:ok)
    form = Nokogiri::HTML(response.body).
      at_css("form[action='#{password_change_path(id: token)}']")
    expect(form.at_css('input[name="password_change_user[password]"]')).
      to be_present
    expect(form.at_css('input[name="password_change_user[otp_attempt]"]')).
      to be_present
    expect(response.headers['Set-Cookie']).to be_nil
    expect(request.env['warden'].user(scope: :user)).to be_nil
    expect(user.reload.reset_password_token).to be_present
    reset_password(token)
    expect(response).to have_http_status(422)
    expect(user.reload.valid_password?(password)).to be true
    reset_password(token, confirmation: 'different-password', code: codes.first)
    expect(response).to have_http_status(422)
    reset_password(token, code: codes.first)
    expect(response).to redirect_to(signin_path)
    expect(user.reload.otp_secret).to eq(original_secret)
    expect(request.env['warden'].user(scope: :user)).to be_nil
    login(password_value: 'changed-invented-password')
    expect(response).to have_http_status(422)
    login(password_value: 'changed-invented-password', code: codes.first)
    expect(response).to have_http_status(422)
    login(password_value: 'changed-invented-password', code: codes.second)
    get '/sidekiq'
    expect(response).to have_http_status(:ok)
  end

  it 'keeps a TOTP account’s password and session when reset lacks a valid code' do
    codes = enrol
    login(code: codes.first)
    token = user.send_reset_password_instructions
    reset_password(token, code: '000000')
    expect(response).to have_http_status(422)
    expect(user.reload.valid_password?(password)).to be true
    get show_user_profile_path(user.url_name)
    expect(response).to have_http_status(:ok)
  end

  it 'limits password reset attempts per token across IP addresses' do
    codes = enrol
    token = user.send_reset_password_instructions
    5.times do |i|
      reset_password(token, code: '000000',
                            headers: origin.merge(
                              'REMOTE_ADDR' => "198.51.100.#{i + 1}"
                            ))
    end
    reset_password(token, code: codes.first,
                          headers: origin.merge(
                            'REMOTE_ADDR' => '198.51.100.99'
                          ))
    expect(response).to have_http_status(:too_many_requests)
    expect(user.reload.valid_password?(password)).to be true
  end

  it 'counts reset attempts without keeping the link' do
    counted = []
    allow(Users::PasswordsController.cache_store).
      to receive(:increment).and_wrap_original do |original, key, *rest, **opts|
        counted << key
        original.call(key, *rest, **opts)
      end
    token = user.send_reset_password_instructions
    reset_password(token, confirmation: 'a-different-password')
    expect(counted.grep(/reset-token/)).not_to be_empty
    expect(counted.join).not_to include(token)
  end

  it 'keeps an authenticator code for another try when the password is refused' do
    enrol
    token = user.send_reset_password_instructions
    code = user.reload.current_otp
    reset_password(token, confirmation: 'a-different-password', code: code)
    expect(response).to have_http_status(422)
    expect(user.reload.consumed_timestep).to be_nil
    reset_password(token, code: code)
    expect(response).to redirect_to(signin_path)
  end

  it 'says after a reset with a code that signing in takes another' do
    codes = enrol
    reset_password(user.send_reset_password_instructions, code: codes.first)
    expect(response).to redirect_to(signin_path)
    expect(flash[:notice]).to eq(
      'Password changed. Sign in with your new password and your next ' \
      'authenticator code or another recovery code.'
    )
    login(password_value: 'changed-invented-password', code: codes.first)
    expect(response).to have_http_status(422)
    login(password_value: 'changed-invented-password', code: codes.second)
    expect(response).to have_http_status(:see_other)

    plain = FactoryBot.create(:user)
    reset_password(plain.send_reset_password_instructions)
    expect(flash[:notice]).to eq('Password changed. Please sign in.')
  end

  it 'refuses reset fields that are not the form’s' do
    token = user.send_reset_password_instructions
    [{ password_change_user: 'a string' },
     { password_change_user: %w[a list] }, {}].each do |sent|
      patch password_change_path(id: token), params: sent, headers: origin
      expect(response).to have_http_status(422)
    end
    expect(user.reload.valid_password?(password)).to be true
  end

  it 'limits email change attempts per account across IP addresses' do
    login
    5.times do |i|
      post signchangeemail_path,
        params: { signchangeemail: { new_email: 'changed@example.test',
                                     password: 'wrong-password' } },
        headers: origin.merge('REMOTE_ADDR' => "198.51.100.#{i + 1}")
    end
    post signchangeemail_path,
      params: { signchangeemail: { new_email: 'changed@example.test',
                                   password: password } },
      headers: origin.merge('REMOTE_ADDR' => '198.51.100.99')
    expect(response).to have_http_status(:too_many_requests)
    expect(PendingEmailChange.count).to eq(0)
  end

  it 'rejects expired and reused reset links without changing the account' do
    token = user.send_reset_password_instructions
    travel 61.minutes do
      reset_password(token)
      expect(response).to have_http_status(422)
    end
    expect(user.reload.valid_password?(password)).to be true
    reset_password(token)
    expect(response).to redirect_to(signin_path)
    reset_password(token, 'another-invented-password')
    expect(response).to have_http_status(422)
    expect(user.reload.valid_password?('changed-invented-password')).to be true
  end

  it 'limits attempts against the normalized email address' do
    5.times {
      login(email: "  #{user.email.upcase}  ", password_value: 'wrong-password')
    }
    login(password_value: 'wrong-password')
    expect(response).to have_http_status(:too_many_requests)
    expect(request.env['warden'].user(scope: :user)).to be_nil
  end

  it 'limits attempts from one IP even when the email changes' do
    10.times { |i|
      login(email: "invented-#{i}@example.test",
            password_value: 'wrong-password')
    }
    login
    expect(response).to have_http_status(:too_many_requests)
    expect(request.env['warden'].user(scope: :user)).to be_nil
  end

  it 'revokes a copied authenticated cookie at logout and ignores remember-me' do
    login
    name = Rails.application.config.session_options[:key]
    old_cookie = cookies[name]
    delete signout_path, headers: origin
    cookies[name] = old_cookie
    get show_user_profile_path(user.url_name)
    expect(response).to have_http_status(:not_found)
    post signin_path,
      params: { user_signin: { email: user.email, password: password,
                               remember_me: '1' } }, headers: origin
    travel 3.hours + 1.second do
      get show_user_profile_path(user.url_name)
      expect(response.status).not_to eq(200)
      expect(response.body).not_to include(user.email)
    end
  end

  it 'denies the first admin and Sidekiq responses after role removal' do
    user.add_role(:admin)
    codes = enrol
    login(code: codes.first)
    user.remove_role(:admin)
    get '/sidekiq'
    expect(response).to have_http_status(:not_found)
    get admin_general_index_path
    expect(response).to have_http_status(:not_found)
  end

  it 'requires both factors for generating recovery codes and cannot disable admin TOTP' do
    user.add_role(:admin)
    codes = enrol
    login(code: codes.first)
    before_codes = user.reload.otp_backup_codes
    post one_time_password_backup_codes_path, params: { password: password },
                                              headers: origin
    expect(response).to have_http_status(422)
    expect(user.reload.otp_backup_codes).to eq(before_codes)
    post one_time_password_backup_codes_path,
      params: { password: password, otp_code: codes.second }, headers: origin
    expect(response).to have_http_status(:ok)
    expect(user.reload.otp_backup_codes.size).to eq(12)
    expect(user.invalidate_otp_backup_code!(codes.third)).to be false
    delete one_time_password_path,
      params: { password: password, otp_code: user.current_otp },
      headers: origin
    expect(response).to have_http_status(:forbidden)
    expect(user.reload.totp?).to be true
  end

  it 'requires fresh factors to request and apply an email change' do
    codes = enrol
    login(code: codes.first)
    post signchangeemail_path,
      params: { signchangeemail: { new_email: 'changed@example.test',
                                   password: password } }, headers: origin
    expect(response).to have_http_status(422)
    expect(PendingEmailChange.count).to eq(0)
    post signchangeemail_path,
      params: { signchangeemail: { new_email: 'changed@example.test',
                                   password: password,
                                   otp_attempt: codes.second } },
      headers: origin
    expect(response).to have_http_status(:ok)
    token = ActionMailer::Base.deliveries.find { |m|
      m.to == ['changed@example.test']
    }.body.decoded.match(%r{/profile/change_email/confirm/([0-9a-f]+)})[1]
    post confirm_email_change_path(email_token: token),
      params: { signchangeemail: { password: password,
                                   otp_attempt: codes.second } },
      headers: origin
    expect(response).to have_http_status(422)
    post confirm_email_change_path(email_token: token),
      params: { signchangeemail: { password: password,
                                   otp_attempt: codes.third } },
      headers: origin
    expect(response).to redirect_to(signin_path)
    expect(user.reload.email).to eq('changed@example.test')
    expect(request.env['warden'].user(scope: :user)).to be_nil
  end

  it 'cannot confirm a different account’s email change while signed in' do
    token = PendingEmailChange.issue(user, 'changed@example.test')
    other = FactoryBot.create(:user, password: password)
    login(email: other.email)
    post confirm_email_change_path(email_token: token),
      params: { signchangeemail: { password: password } }, headers: origin
    expect(response).to have_http_status(:not_found)
    expect(user.reload.email).not_to eq('changed@example.test')
    expect(PendingEmailChange.find_by_token(token).consumed_at).to be_nil
  end

  def start_set_up(account)
    post start_one_time_password_path, params: { password: password },
                                       headers: origin
    AuthenticationEnrolment.where(user: account).order(:id).last
  end

  def finish_set_up(challenge)
    post one_time_password_path,
      params: { otp_code: ROTP::TOTP.new(challenge.secret).now },
      headers: origin
  end

  it 'never carries an unfinished set-up, or its secret, to the next account' do
    other = FactoryBot.create(:user, password: password)
    login
    first = start_set_up(user)
    delete signout_path, headers: origin
    get new_one_time_password_path
    expect(response).to redirect_to(signin_path(r: new_one_time_password_path))
    finish_set_up(first)
    expect(response).to redirect_to(signin_path)
    expect(user.reload.totp?).to be false

    login(email: other.email)
    second = start_set_up(other)
    expect(second.secret).not_to eq(first.secret)
    get new_one_time_password_path
    expect(response.body).to include(second.secret)
    expect(response.body).not_to include(first.secret)
    # The first account's code is no use to the second account's set-up.
    post one_time_password_path,
      params: { otp_code: ROTP::TOTP.new(first.secret).now }, headers: origin
    expect(response).to have_http_status(422)
    expect(other.reload.totp?).to be false
    finish_set_up(second)
    expect(response).to have_http_status(:ok)
    expect(other.reload.otp_secret).to eq(second.secret)
    expect(user.reload.totp?).to be false
    expect(user.otp_secret).to be_nil
  end

  it 'ends an unfinished set-up when another account signs in over it' do
    other = FactoryBot.create(:user, password: password)
    login
    first = start_set_up(user)
    login(email: other.email)
    expect(request.env['warden'].user(scope: :user)).to eq(other)
    get new_one_time_password_path
    expect(response.body).not_to include(first.secret)
    finish_set_up(first)
    expect(response).to redirect_to(signin_path)
    expect(user.reload.totp?).to be false
    expect(other.reload.totp?).to be false
  end

  it 'ends an unfinished set-up when a sign-in fails' do
    login
    challenge = start_set_up(user)
    login(password_value: 'not-the-password')
    expect(response).to have_http_status(422)
    expect(request.env['warden'].user(scope: :user)).to be_nil
    get new_one_time_password_path
    expect(response).to redirect_to(signin_path(r: new_one_time_password_path))
    finish_set_up(challenge)
    expect(response).to redirect_to(signin_path)
    expect(user.reload.totp?).to be false
  end

  it 'ends a sign-in waiting on set-up when the password changes' do
    user.add_role(:admin)
    login
    expect(response).to redirect_to(new_one_time_password_path)
    challenge = AuthenticationEnrolment.last
    user.update!(password: 'changed-invented-password')
    get new_one_time_password_path
    expect(response.body).not_to include(challenge.secret)
    finish_set_up(challenge)
    expect(response).to redirect_to(signin_path)
    expect(request.env['warden'].user(scope: :user)).to be_nil
    expect(user.reload.totp?).to be false
  end

  it 'ends other sessions and a waiting email change when the password changes' do
    login
    token = PendingEmailChange.issue(user, 'changed@example.test')
    get show_user_profile_path(user.url_name)
    expect(response).to have_http_status(:ok)
    user.update!(password: 'changed-invented-password')
    get show_user_profile_path(user.url_name)
    expect(response).to have_http_status(:not_found)
    login(password_value: 'changed-invented-password')
    post confirm_email_change_path(email_token: token),
      params: { signchangeemail: { password: 'changed-invented-password' } },
      headers: origin
    expect(response).to have_http_status(:not_found)
    expect(user.reload.email).not_to eq('changed@example.test')
  end

  it 'does not accept cross-site signed-out login submissions' do
    ActionController::Base.allow_forgery_protection = true
    post signin_path,
      params: { user_signin: { email: user.email, password: password } },
      headers: { 'Origin' => 'https://other.example.test' }
    expect(response.status).to be_in([403, 422])
    expect(request.env['warden'].user(scope: :user)).to be_nil
  end

  it 'requires a CSRF token for authenticated credential changes' do
    login
    ActionController::Base.allow_forgery_protection = true
    expect do
      post signchangeemail_path,
        params: { signchangeemail: { new_email: 'changed@example.test',
                                     password: password } }, headers: origin
    end.not_to change(PendingEmailChange, :count)
    expect(response.status).to be_in([403, 422])
  end
end
