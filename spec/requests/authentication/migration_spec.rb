require 'spec_helper'

RSpec.describe 'Devise authentication boundaries', type: :request do
  let(:password) { 'invented-long-password' }
  let(:user) do
    FactoryBot.create(:user, email: 'authentication-owner@example.test',
                             password: password)
  end

  def login(account = user, code: nil, password_value: password)
    post '/profile/sign_in', params: { user_signin: {
      email: account.email, password: password_value, otp_attempt: code
    } }, headers: { 'Origin' => "http://#{host}" }
  end

  def enable_totp(account)
    account.update!(otp_secret: User.generate_otp_secret,
                    otp_required_for_login: true)
  end

  it 'installs only the intended Devise modules and no database-only strategy' do
    expect(User.devise_modules).to include(:two_factor_authenticatable,
      :two_factor_backupable, :recoverable, :confirmable, :timeoutable)
    expect(User.devise_modules).not_to include(:database_authenticatable,
      :rememberable)
    expect(Devise.sign_in_after_reset_password).to be false
  end

  it 'signs in a confirmed ordinary user and displays their private profile' do
    login
    expect(response).to have_http_status(:see_other)
    get show_user_profile_path(user.url_name)
    expect(response).to have_http_status(:ok)
    expect(response.body).to include(user.email)
  end

  it 'never accepts a legacy password or user-ID cookie strategy' do
    expect(user).not_to respond_to(:has_this_password?)
    expect(User).not_to respond_to(:authenticate_from_session)
    user.update_columns(encrypted_password: '', credential_reset_required: true)
    login
    expect(response).to have_http_status(422)
    get show_user_profile_path(user.url_name)
    expect(response).to have_http_status(:not_found)
  end

  it 'denies password-only and OTP-only attempts and accepts both factors' do
    enable_totp(user)
    login
    expect(response).to have_http_status(422)
    login(code: user.current_otp, password_value: '')
    expect(response).to have_http_status(422)
    login(code: user.current_otp)
    expect(response).to have_http_status(:see_other)
    get show_user_profile_path(user.url_name)
    expect(response).to have_http_status(:ok)
  end

  it 'denies the very first profile response after three hours of inactivity' do
    login
    travel 3.hours + 1.second do
      get show_user_profile_path(user.url_name)
      expect(response.status).to be_in([302, 303, 404])
      expect(response.body).not_to include(user.email)
    end
  end

  it 'never creates a session from a reset link' do
    token = user.send_reset_password_instructions
    patch password_change_path(reset_password_token: token),
          params: {
            password_change_user: {
              password: 'another-invented-password',
              password_confirmation: 'another-invented-password'
            }
          }
    expect(response).to redirect_to(signin_path)
    expect(user.reload.valid_password?('another-invented-password')).to be true
    get show_user_profile_path(user.url_name)
    expect(response).to have_http_status(:not_found)
  end

  it 'uses a recovery code once, together with the password' do
    enable_totp(user)
    codes = user.generate_otp_backup_codes!
    user.save!
    login(code: codes.first)
    expect(response).to have_http_status(:see_other)
    expect(user.reload.otp_backup_codes.size).to eq(11)
    delete signout_path
    login(code: codes.first)
    expect(response).to have_http_status(422)
  end
end
