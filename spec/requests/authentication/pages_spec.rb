require 'spec_helper'

RSpec.describe 'Sign-in pages', type: :request do
  include_context 'consider all requests remote'

  let(:password) { 'invented-user-password' }
  let(:user) { FactoryBot.create(:user, password: password) }
  let(:origin) { { 'Origin' => "http://#{host}" } }

  def page
    Nokogiri::HTML(response.body)
  end

  def login(account = user, code: nil)
    post signin_path, params: { user_signin: {
      email: account.email, password: password, otp_attempt: code
    } }, headers: origin
  end

  def turn_on_app
    user.update!(otp_secret: User.generate_otp_secret,
                 otp_required_for_login: true)
    codes = user.generate_otp_backup_codes!
    user.save!
    codes
  end

  def error_message
    page.at_css('#error')&.text.to_s.strip
  end

  def title
    page.at_css('title').text.squish
  end

  describe 'a wrong password' do
    it 'shows the set-up form again when starting the authenticator' do
      login
      post start_one_time_password_path, params: { password: 'wrong' },
                                         headers: origin
      expect(response).to have_http_status(422)
      expect(error_message).to eq('That password was not recognised.')
      expect(page.at_css("form[action='#{start_one_time_password_path}']")).
        to be_present
      expect(AuthenticationEnrolment.count).to eq(0)
    end

    it 'shows the form again when turning the authenticator off' do
      codes = turn_on_app
      login(code: codes.first)
      delete one_time_password_path,
        params: { password: 'wrong', otp_code: codes.second }, headers: origin
      expect(response).to have_http_status(422)
      expect(error_message).to eq('The password or code was not recognised.')
      expect(page.at_css("form[action='#{one_time_password_path}']")).
        to be_present
      expect(user.reload.totp?).to be true
    end

    it 'shows the form again when making new recovery codes' do
      codes = turn_on_app
      login(code: codes.first)
      before = user.reload.otp_backup_codes
      post one_time_password_backup_codes_path,
        params: { password: 'wrong', otp_code: codes.second }, headers: origin
      expect(response).to have_http_status(422)
      expect(error_message).to eq('The password or code was not recognised.')
      expect(page.at_css('form input[name=otp_code]')).to be_present
      expect(user.reload.otp_backup_codes).to eq(before)
    end

    it 'shows the form again, with the address typed, when changing email' do
      login
      post signchangeemail_path, params: { signchangeemail: {
        new_email: 'moved@example.test', password: 'wrong'
      } }, headers: origin
      expect(response).to have_http_status(422)
      expect(error_message).to eq('That password was not recognised.')
      expect(page.at_css('#signchangeemail_new_email')['value']).
        to eq('moved@example.test')
      expect(PendingEmailChange.count).to eq(0)
    end

    it 'shows the confirm form again when confirming a new address' do
      login
      token = PendingEmailChange.issue(user, 'moved@example.test')
      post confirm_email_change_path(email_token: token),
        params: { signchangeemail: { password: 'wrong' } }, headers: origin
      expect(response).to have_http_status(422)
      expect(error_message).to eq('That password was not recognised.')
      expect(response.body).to include('moved@example.test')
      expect(user.reload.email).not_to eq('moved@example.test')
    end
  end

  it 'does not say which was wrong when a code was needed too' do
    codes = turn_on_app
    login(code: codes.first)
    post signchangeemail_path, params: { signchangeemail: {
      new_email: 'moved@example.test', password: password,
      otp_attempt: 'not-a-code'
    } }, headers: origin
    expect(response).to have_http_status(422)
    expect(error_message).to eq('The password or code was not recognised.')
    expect(PendingEmailChange.count).to eq(0)
  end

  it 'asks for a valid address when changing email' do
    login
    post signchangeemail_path, params: { signchangeemail: {
      new_email: 'not an address', password: password
    } }, headers: origin
    expect(response).to have_http_status(422)
    expect(error_message).to eq('Please enter a valid email address.')
    expect(PendingEmailChange.count).to eq(0)
  end

  it 'takes no address for the email form from a link' do
    login
    [{ signchangeemail: 'not-a-form' },
     { signchangeemail: { new_email: 'planted@example.test' } }].each do |query|
      get signchangeemail_path, params: query
      expect(response).to have_http_status(:ok)
      expect(page.at_css('#signchangeemail_new_email')['value']).to be_nil
    end
  end

  it 'has no page for an email link whose address another account took' do
    login
    token = PendingEmailChange.issue(user, 'moved@example.test')
    FactoryBot.create(:user, email: 'moved@example.test')
    get confirm_email_change_path(email_token: token)
    expect(response).to have_http_status(:not_found)
    post confirm_email_change_path(email_token: token),
      params: { signchangeemail: { password: password } }, headers: origin
    expect(response).to have_http_status(:not_found)
    expect(user.reload.email).not_to eq('moved@example.test')
  end

  it 'asks for an authenticator code on password reset only when enabled' do
    plain_token = user.send_reset_password_instructions
    get edit_password_change_path(reset_password_token: plain_token)
    expect(page.at_css('#password_change_user_otp_attempt')).to be_nil

    turn_on_app
    totp_token = user.send_reset_password_instructions
    get edit_password_change_path(reset_password_token: totp_token)
    expect(page.at_css('#password_change_user_otp_attempt')).to be_present

    next_password = 'another-long-password'
    patch password_change_path(reset_password_token: totp_token),
      params: { password_change_user: { password: next_password,
                                        password_confirmation: next_password,
                                        otp_attempt: 'not-a-code' } },
      headers: origin
    expect(response).to have_http_status(422)
    expect(page.at_css('#errorExplanation')&.text).
      to include('Invalid or expired authentication code.')
    expect(page.at_css('#password_change_user_otp_attempt')).to be_present

    travel 61.minutes do
      get edit_password_change_path(reset_password_token: totp_token)
      expect(page.at_css('#password_change_user_otp_attempt')).to be_nil
    end
  end

  it 'explains two factor authentication to an account without it' do
    login
    get one_time_password_path
    expect(response.body).to include('What is Two Factor Authentication?')
  end

  describe 'something tried too often' do
    it 'gets a page that says so' do
      6.times do
        post signin_path, params: { user_signin: {
          email: user.email, password: 'wrong'
        } }, headers: origin
      end
      expect(response).to have_http_status(:too_many_requests)
      expect(title).to start_with('Too many attempts')
      expect(response.body).to include('There have been too many attempts')
      expect(request.env['warden'].user(scope: :user)).to be_nil
    end

    it 'gets the same page when signed in' do
      login
      6.times do
        post signchangeemail_path, params: { signchangeemail: {
          new_email: 'moved@example.test', password: 'wrong'
        } }, headers: origin
      end
      expect(response).to have_http_status(:too_many_requests)
      expect(title).to start_with('Too many attempts')
      expect(PendingEmailChange.count).to eq(0)
    end
  end

  describe 'a request written before signing in' do
    def write_letter
      post new_request_path, params: {
        submitted_new_request: 1,
        info_request: { title: 'Invented library expenditure',
                        public_body_id: FactoryBot.create(:public_body).id },
        outgoing_message: { body: "Dear Authority,\nPlease supply the " \
                                  "invented library totals.\nYours " \
                                  "faithfully,\nExample Author" }
      }, headers: origin
    end

    def close_signups
      allow(AlaveteliConfiguration).
        to receive(:read_only_features).and_return(['signups'])
    end

    def reason
      page.at_css('#sign_in_reason')&.text&.squish
    end

    it 'leads to the sign-up page, which mentions it' do
      write_letter
      expect(response).to redirect_to('/profile/sign_up')
      follow_redirect!
      expect(reason).to eq('Your request is saved and has not been sent. ' \
                           'Create an account to carry on with it.')
    end

    it 'is mentioned on the sign-in page too, for someone with an account' do
      write_letter
      get signin_path
      expect(reason).to eq('Your request is saved and has not been sent. ' \
                           'Sign in to carry on with it.')
    end

    it 'leads to the sign-in page when sign-ups are closed' do
      close_signups
      write_letter
      expect(response).to redirect_to('/profile/sign_in')
      follow_redirect!
      expect(reason).to eq('Your request is saved and has not been sent. ' \
                           'Sign in to carry on with it.')
    end

    it 'is kept when sign-ups close before the sign-up page is reached' do
      write_letter
      close_signups
      follow_redirect!
      expect(response).to redirect_to('/profile/sign_in')
      follow_redirect!
      expect(reason).to eq('Your request is saved and has not been sent. ' \
                           'Sign in to carry on with it.')
    end

    it 'is not mentioned to someone who wrote none' do
      [signin_path, signup_path].each do |path|
        get path
        expect(response).to have_http_status(:ok), path
        expect(reason).to be_nil, path
      end
    end
  end

  describe 'the confirmation page' do
    def confirmation_path_for(account, **params)
      account.send_confirmation_instructions
      token = ActionMailer::Base.deliveries.last.body.decoded.
        match(%r{/c/([^?\s<]+)})[1]
      confirm_path(email_token: token, **params)
    end

    let(:unconfirmed) do
      FactoryBot.create(:user, email_confirmed: false, confirmed_at: nil)
    end

    def claim_for(account)
      letter = PendingRequestDraft.capture({},
        title: 'Invented library expenditure', body: 'Invented body',
        public_body_id: FactoryBot.create(:public_body).id)
      letter.bind_to(account)
      letter.transfer_token
    end

    it 'says nothing about a request to someone who wrote none' do
      get confirmation_path_for(unconfirmed)
      expect(response).to have_http_status(:ok)
      expect(response.body).not_to include('Your request is saved')
    end

    it 'says the request is saved while the letter is kept' do
      get confirmation_path_for(unconfirmed,
        draft_claim: claim_for(unconfirmed))
      expect(response.body).
        to include('Your request is saved and has not been sent.')
    end

    it 'asks again, still saying the request is saved, for a refused password' do
      path = confirmation_path_for(unconfirmed,
        draft_claim: claim_for(unconfirmed))
      refused = { password: 'too short', password_confirmation: 'too short' }
      post path, params: { confirm_user: refused }, headers: origin
      expect(response).to have_http_status(422)
      expect(page.css('#content h1').map(&:text)).
        to eq(['Confirm your email address'])
      expect(response.body).
        to include('Your request is saved and has not been sent.')
      expect(page.at_css('input[autocomplete="username"]')['value']).
        to eq(unconfirmed.email)
      expect(unconfirmed.reload.confirmed?).to be false
    end

    it 'says nothing once the letter has gone' do
      path = confirmation_path_for(unconfirmed,
        draft_claim: claim_for(unconfirmed))
      travel 31.minutes do
        get path
        expect(response).to have_http_status(:ok)
        expect(response.body).not_to include('Your request is saved')
      end
    end

    it 'says nothing for a claim that is made up or another account’s' do
      ['a-claim', claim_for(user)].each do |claim|
        get confirmation_path_for(unconfirmed, draft_claim: claim)
        expect(response).to have_http_status(:ok)
        expect(response.body).not_to include('Your request is saved')
      end
    end
  end

  describe 'titles' do
    it 'names each signed-out page' do
      {
        signin_path => 'Sign in',
        signup_path => 'Create an account',
        new_password_change_path => 'Reset your password',
        new_user_confirmation_path => 'Resend confirmation email'
      }.each do |path, heading|
        get path
        expect(title).to start_with(heading), path
      end
    end

    it 'names each signed-in page' do
      login
      {
        one_time_password_path => 'Two factor authentication',
        new_one_time_password_path => 'Set up two factor authentication',
        signchangeemail_path => 'Change your email address',
        signout_path => 'Sign out'
      }.each do |path, heading|
        get path
        expect(title).to start_with(heading), path
      end
    end
  end
end
