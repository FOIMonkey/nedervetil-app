require 'spec_helper'

RSpec.describe 'Authentication journeys', type: :request do
  include_context 'consider all requests remote'

  let(:password) { 'invented-owner-password' }
  let(:user) { FactoryBot.create(:user, password: password) }
  let(:authority) { FactoryBot.create(:public_body) }
  let(:origin) { { 'Origin' => "http://#{host}" } }

  def login(account = user, code: nil, return_to: nil)
    data = { user_signin: { email: account.email, password: password,
                            otp_attempt: code } }
    data[:r] = return_to if return_to
    post signin_path,
      params: data, headers: origin
  end

  def capture_letter
    post new_request_path, params: {
      submitted_new_request: 1,
      info_request: { title: 'Invented library expenditure',
                      public_body_id: authority.id },
      outgoing_message: {
        body: 'Dear Authority,\n' \
              'Please supply the invented library totals.\n' \
              'Yours faithfully,\n' \
              'Example Author'
      },
      password: 'must-not-be-captured', arbitrary: 'must-not-be-captured'
    }, headers: origin
    expect(response).to redirect_to(signup_path)
    PendingRequestDraft.last
  end

  def confirmation_token(account)
    account.send_confirmation_instructions
    ActionMailer::Base.deliveries.last.body.decoded.match(%r{/c/([^?\s<]+)})[1]
  end

  def choose_password(chosen = password, confirmation = chosen)
    { confirm_user: { password: chosen, password_confirmation: confirmation } }
  end

  # strict-origin keeps Origin intact for signed-out form posts (no-referrer
  # sends Origin: null) while stripping token paths from Referer.
  it 'serves the signed-out authentication pages with strict-origin' do
    reset_token = user.send_reset_password_instructions
    unconfirmed = FactoryBot.create(:unconfirmed_user, password: password)
    [signin_path, signup_path, new_password_change_path,
     edit_password_change_path(reset_password_token: reset_token),
     new_user_confirmation_path,
     confirm_path(email_token: confirmation_token(unconfirmed))].each do |path|
      get path
      expect(response).to have_http_status(:ok), path
      expect(response.headers['Referrer-Policy']).to eq('strict-origin'), path
    end
  end

  it 'requires enrolment before an admin has a Warden session or sees private data' do
    user.add_role(:admin)
    login
    expect(response).to redirect_to(new_one_time_password_path)
    expect(request.env['warden'].user(scope: :user)).to be_nil
    get show_user_profile_path(user.url_name)
    expect(response).to have_http_status(:not_found)
    get '/sidekiq'
    expect(response).to have_http_status(:not_found)
    get new_one_time_password_path
    expect(response).to have_http_status(:ok)
    challenge = AuthenticationEnrolment.last
    post one_time_password_path,
      params: { otp_code: ROTP::TOTP.new(challenge.secret).now },
      headers: origin
    expect(response).to have_http_status(:ok)
    expect(response.body).to include('recovery codes')
    expect(response.headers['Cache-Control']).to include('no-store')
    expect(response.headers['Referrer-Policy']).to eq('strict-origin')
    expect(response.body).to include('turbo-cache-control')
    expect(user.reload.totp?).to be true
    expect(user.validate_and_consume_otp!(user.current_otp)).to be false
    get '/sidekiq'
    expect(response).to have_http_status(:ok)
    travel 3.hours + 1.second do
      get '/sidekiq'
      expect(response.status).to be_in([302, 303, 404])
      expect(response.body).not_to include('Sidekiq v')
    end
  end

  it 'denies admin entry when the global flag is off, including an existing session' do
    user.add_role(:admin)
    user.update!(otp_secret: User.generate_otp_secret,
                 otp_required_for_login: true)
    login(code: user.current_otp)
    expect(response).to have_http_status(:see_other)
    allow(AlaveteliConfiguration).
      to receive(:enable_two_factor_auth).and_return(false)
    get '/sidekiq'
    expect(response.status).to be_in([302, 303, 404])
    get admin_general_index_path
    expect(response.status).not_to eq(200)
    login(code: user.current_otp)
    expect(response).to have_http_status(422)
  end

  it 'keeps an ordinary user out of both admin boundaries' do
    login
    get '/sidekiq'
    expect(response).to have_http_status(:not_found)
    get admin_general_index_path
    expect(response).to have_http_status(:not_found)
  end

  it 'expires an enrolment challenge and invalidates it on credential change' do
    user.add_role(:admin)
    login
    challenge = AuthenticationEnrolment.last
    travel 6.minutes do
      post one_time_password_path,
        params: { otp_code: ROTP::TOTP.new(challenge.secret).now },
        headers: origin
      expect(response).to redirect_to(signin_path)
    end
    user.update!(password: 'changed-invented-password')
    expect(challenge.reload.usable?).to be false
    expect(user.reload.totp?).to be false
  end

  it 'keeps registration closed and creates no user, draft or session' do
    allow(AlaveteliConfiguration).
      to receive(:read_only_features).and_return(['signups'])
    expect do
      post signup_path,
        params: { user_signup: { name: 'Invented Person',
                                 email: 'signup@example.test' } },
        headers: origin
    end.not_to change(User, :count)
    expect(request.env['warden'].user(scope: :user)).to be_nil
  end

  it 'registers without auto-login, confirms by POST only, and signs in separately' do
    allow(AlaveteliConfiguration).to receive(:read_only_features).and_return([])
    get signup_path(r: '/help/about')
    target = Nokogiri::HTML(response.body).
      at_css('#signup_form input[name="r"]')['value']
    expect(AuthenticationReturn.count).to eq(0)
    expect(response.headers['Set-Cookie']).to be_nil
    post signup_path,
      params: { r: target, user_signup: { name: 'Invented Person',
                                          email: 'signup@example.test' } },
      headers: origin
    expect(response).to have_http_status(:ok)
    account = User.find_by!(email: 'signup@example.test')
    saved = AuthenticationReturn.last
    expect(saved.user).to eq(account)
    expect(request.env['warden'].user(scope: :user)).to be_nil
    token = ActionMailer::Base.deliveries.last.body.decoded.match(%r{/c/([^?\s<]+)})[1]
    get confirm_path(email_token: token)
    expect(account.reload.confirmed?).to be false
    post confirm_path(email_token: token), params: choose_password,
                                           headers: origin
    expect(account.reload.confirmed?).to be true
    expect(request.env['warden'].user(scope: :user)).to be_nil
    expect(saved.reload.consumed_at).to be_nil
    post confirm_path(email_token: token), headers: origin
    expect(response).to have_http_status(:not_found)
    login(account)
    expect(response).to redirect_to('/help/about')
    expect(saved.reload.consumed_at).to be_present
  end

  it 'confirms only with a password the mailbox owner chooses' do
    stranger_password = 'stranger-invented-password'
    account = FactoryBot.create(:unconfirmed_user, password: stranger_password)
    token = confirmation_token(account)
    get confirm_path(email_token: token)
    expect(response.body).to include('confirm_user[password]')

    [choose_password(nil), choose_password(password, 'something else'),
     choose_password('too short')].each do |params|
      post confirm_path(email_token: token), params: params, headers: origin
      expect(response).to have_http_status(422)
      expect(response.body).to include('confirm_user[password]')
      expect(account.reload.confirmed?).to be false
    end

    post confirm_path(email_token: token), params: choose_password,
                                           headers: origin
    expect(response).to redirect_to(signin_path)
    account.reload
    expect(account.confirmed?).to be true
    expect(account.valid_password?(stranger_password)).to be false
    expect(account.valid_password?(password)).to be true
  end

  it 'keeps a pre-registered account unusable to whoever made it' do
    allow(AlaveteliConfiguration).to receive(:read_only_features).and_return([])
    stranger_password = 'stranger-invented-password'
    account = FactoryBot.create(:unconfirmed_user, password: stranger_password)
    post signup_path,
      params: { user_signup: { name: 'Mailbox Owner', email: account.email } },
      headers: origin
    token = ActionMailer::Base.deliveries.last.body.decoded.match(%r{/c/([^?\s<]+)})[1]
    post confirm_path(email_token: token), params: choose_password,
                                           headers: origin
    expect(account.reload.confirmed?).to be true
    expect(account.name).to eq('Mailbox Owner')
    post signin_path,
      params: { user_signin: { email: account.email,
                               password: stranger_password } },
      headers: origin
    expect(request.env['warden'].user(scope: :user)).to be_nil
    login(account)
    expect(request.env['warden'].user(scope: :user)).to eq(account)
  end

  it 'leaves a confirmed account’s name alone on a second sign-up' do
    allow(AlaveteliConfiguration).to receive(:read_only_features).and_return([])
    sent = ActionMailer::Base.deliveries.size
    post signup_path,
      params: { user_signup: { name: 'Someone Else', email: user.email } },
      headers: origin
    expect(response.body).to include('Check your email')
    expect(user.reload.name).not_to eq('Someone Else')
    expect(ActionMailer::Base.deliveries.size).to eq(sent)
  end

  it 'refuses a bad name the same way whether or not the address has an account' do
    allow(AlaveteliConfiguration).to receive(:read_only_features).and_return([])
    unconfirmed = FactoryBot.create(:unconfirmed_user)
    named = unconfirmed.name
    sent = ActionMailer::Base.deliveries.size
    [unconfirmed.email, 'nobody-yet@example.test'].each do |address|
      post signup_path,
        params: { user_signup: { name: 'someone@example.test',
                                 email: address } },
        headers: origin
      expect(response).to have_http_status(422), address
      expect(response.body).to include('not your email address'), address
    end
    expect(unconfirmed.reload.name).to eq(named)
    expect(ActionMailer::Base.deliveries.size).to eq(sent)
  end

  it 'confirms an unconfirmed account when its password is reset' do
    account = FactoryBot.create(:unconfirmed_user)
    confirm = confirmation_token(account)
    travel 2.days do # the confirmation link has expired
      reset = account.send_reset_password_instructions
      patch password_change_path(reset_password_token: reset),
        params: { password_change_user: { password: password,
                                          password_confirmation: password } },
        headers: origin
      expect(response).to redirect_to(signin_path)
      expect(account.reload.confirmed?).to be true
      expect(account.email_confirmed).to be true
      expect(request.env['warden'].user(scope: :user)).to be_nil
      get confirm_path(email_token: confirm)
      expect(response).to have_http_status(:not_found)
      login(account)
      expect(request.env['warden'].user(scope: :user)).to eq(account)
    end
  end

  it 'confirms nothing when a reset is refused' do
    account = FactoryBot.create(:unconfirmed_user)
    reset = account.send_reset_password_instructions
    patch password_change_path(reset_password_token: reset),
      params: { password_change_user: { password: password,
                                        password_confirmation: 'different' } },
      headers: origin
    expect(response).to have_http_status(422)
    expect(account.reload.confirmed?).to be false
  end

  it 'gives a new account a password nobody knows until confirmation' do
    allow(AlaveteliConfiguration).to receive(:read_only_features).and_return([])
    post signup_path,
      params: { user_signup: { name: 'Invented Person',
                               email: 'signup@example.test' } },
      headers: origin
    account = User.find_by!(email: 'signup@example.test')
    expect(account.encrypted_password).to be_present
    expect(account.confirmed?).to be false
  end

  it 'ignores a password sent with the sign-up form' do
    allow(AlaveteliConfiguration).to receive(:read_only_features).and_return([])
    # Match production by ignoring unpermitted params instead of raising.
    allow(ActionController::Parameters).
      to receive(:action_on_unpermitted_parameters).and_return(false)
    stranger_password = 'stranger-invented-password'
    post signup_path,
      params: { user_signup: { name: 'Invented Person',
                               email: 'typed-a-password@example.test',
                               password: stranger_password,
                               password_confirmation: stranger_password } },
      headers: origin
    account = User.find_by!(email: 'typed-a-password@example.test')
    expect(account.valid_password?(stranger_password)).to be false
    token = ActionMailer::Base.deliveries.last.body.decoded.match(%r{/c/([^?\s<]+)})[1]
    post confirm_path(email_token: token), params: choose_password,
                                           headers: origin
    expect(account.reload.confirmed?).to be true
    expect(account.valid_password?(stranger_password)).to be false
  end

  it 'refuses confirmation fields that are not the form’s' do
    account = FactoryBot.create(:unconfirmed_user)
    token = confirmation_token(account)
    [{ confirm_user: 'a string' }, { confirm_user: %w[a list] }].each do |sent|
      post confirm_path(email_token: token), params: sent, headers: origin
      expect(response).to have_http_status(422)
      expect(response.body).to include('confirm_user[password]')
    end
    expect(account.reload.confirmed?).to be false
  end

  # What another request commits just before this one locks the account.
  def meanwhile
    done = false
    allow_any_instance_of(User).
      to receive(:with_lock).and_wrap_original do |original, *args, &block|
        yield unless done
        done = true
        original.call(*args, &block)
      end
  end

  it 'sends the confirmation form’s second copy on to sign in' do
    account = FactoryBot.create(:unconfirmed_user)
    token = confirmation_token(account)
    meanwhile do
      first = User.find(account.id)
      first.password = password
      first.confirm
    end
    post confirm_path(email_token: token),
      params: choose_password('another-invented-password'), headers: origin
    expect(response).to redirect_to(signin_path)
    expect(account.reload.valid_password?(password)).to be true
  end

  it 'leaves an account alone that is confirmed as a second sign-up arrives' do
    allow(AlaveteliConfiguration).to receive(:read_only_features).and_return([])
    account = FactoryBot.create(:unconfirmed_user)
    named = account.name
    sent = ActionMailer::Base.deliveries.size
    meanwhile { User.find(account.id).confirm }
    post signup_path,
      params: { user_signup: { name: 'Someone Else', email: account.email } },
      headers: origin
    expect(response.body).to include('Check your email')
    expect(account.reload.name).to eq(named)
    expect(ActionMailer::Base.deliveries.size).to eq(sent)
  end

  it 'sends a renewed link to the address the account has now' do
    account = FactoryBot.create(:unconfirmed_user)
    old_address = account.email
    confirmation_token(account)
    travel 2.days do # the link has expired, so a resend makes a new one
      meanwhile do
        User.find(account.id).update!(email: 'corrected@example.test')
      end
      post user_confirmation_path, params: { user: { email: old_address } },
                                   headers: origin
      mail = ActionMailer::Base.deliveries.last
      expect(mail.to).to eq(['corrected@example.test'])
      token = mail.body.decoded.match(%r{/c/([^?\s<]+)})[1]
      expect(account.reload.confirmation_token).to eq(token)
    end
  end

  it 'lets no second sign-up name a suspended account or the site’s own' do
    allow(AlaveteliConfiguration).to receive(:read_only_features).and_return([])
    suspended = FactoryBot.create(:unconfirmed_user, ban_text: 'Banned')
    [suspended, User.internal_admin_user].each do |account|
      named = account.read_attribute(:name)
      post signup_path,
        params: { user_signup: { name: 'Someone Else',
                                 email: account.email } },
        headers: origin
      expect(response.body).to include('Check your email')
      expect(account.reload.read_attribute(:name)).to eq(named)
    end
  end

  it 'keeps a letter written signed out when its author resets the password' do
    allow(AlaveteliConfiguration).to receive(:read_only_features).and_return([])
    capture_letter
    post signup_path,
      params: { user_signup: { name: 'Invented Author',
                               email: 'letter@example.test' } },
      headers: origin
    account = User.find_by!(email: 'letter@example.test')
    reset = account.send_reset_password_instructions
    patch password_change_path(reset_password_token: reset),
      params: { password_change_user: { password: password,
                                        password_confirmation: password } },
      headers: origin
    expect(response).to redirect_to(signin_path)
    expect(request.env['warden'].user(scope: :user)).to be_nil
    expect { login(account) }.
      to change(account.draft_info_requests, :count).by(1)
    expect(account.draft_info_requests.first.body).
      to include('invented library totals')
  end

  it 'gives a kept letter to nobody but its author after a reset' do
    allow(AlaveteliConfiguration).to receive(:read_only_features).and_return([])
    other = FactoryBot.create(:user, password: password)
    pending = capture_letter
    post signup_path,
      params: { user_signup: { name: 'Invented Author',
                               email: 'letter-author@example.test' } },
      headers: origin
    reset = other.send_reset_password_instructions
    patch password_change_path(reset_password_token: reset),
      params: { password_change_user: { password: password,
                                        password_confirmation: password } },
      headers: origin
    expect { login(other) }.not_to change(DraftInfoRequest, :count)
    expect(pending.reload.claimed_at).to be_nil
  end

  it 'does not exchange reset, confirmation and email-change tokens' do
    account = FactoryBot.create(:unconfirmed_user, password: password)
    confirm = confirmation_token(account)
    reset = account.send_reset_password_instructions
    change = PendingEmailChange.issue(account, 'invented-new@example.test')
    [reset, change].each do |token|
      post confirm_path(email_token: token), headers: origin
      expect(response).to have_http_status(:not_found)
    end
    [confirm, change].each do |token|
      patch password_change_path(reset_password_token: token),
        params: {
          password_change_user: {
            password: 'changed-invented-password',
            password_confirmation: 'changed-invented-password'
          }
        },
        headers: origin
      expect(response).to have_http_status(422)
    end
    expect(account.reload.confirmed?).to be false
    expect(account.valid_password?(password)).to be true
    expect(request.env['warden'].user(scope: :user)).to be_nil
  end

  it 'claims an anonymous letter once after full authentication and never sends it' do
    pending = capture_letter
    expect(JSON.parse(pending.payload).keys).to match_array(%w[title body
                                                               public_body_id])
    expect(pending.payload_before_type_cast).
      not_to include('invented library totals')
    expect { login }.to change(user.draft_info_requests, :count).by(1)
    draft = user.draft_info_requests.first
    expect(response).
      to redirect_to(new_alaveteli_pro_info_request_path(draft_id: draft.id))
    expect(draft.body).to include('invented library totals')
    expect(pending.reload.claimed_at).to be_present
    expect(pending.payload).to eq('{}')
    expect(ActionMailer::Base.deliveries).to be_empty
    delete signout_path, headers: origin
    expect { login }.not_to change(DraftInfoRequest, :count)
  end

  it 'binds a pending body to the password-proved account even when OTP is incomplete' do
    pending = capture_letter
    user.update!(otp_secret: User.generate_otp_secret,
                 otp_required_for_login: true)
    login
    expect(response).to have_http_status(422)
    expect(pending.reload.intended_user_id).to eq(user.id)
    other = FactoryBot.create(:user, password: password)
    expect { login(other) }.not_to change(DraftInfoRequest, :count)
    expect(pending.reload.claimed_at).to be_nil
  end

  it 'carries a purpose-bound draft claim through confirmation in another browser' do
    allow(AlaveteliConfiguration).to receive(:read_only_features).and_return([])
    pending = capture_letter
    post signup_path,
      params: { user_signup: { name: 'Invented Author',
                               email: 'cross-browser@example.test' } },
      headers: origin
    account = User.find_by!(email: 'cross-browser@example.test')
    url = URI(ActionMailer::Base.deliveries.last.body.decoded.match(%r{https?://[^\s<]+/c/[^\s<]+})[0])
    confirmation_url = url.path + (url.query ? "?#{url.query}" : '')
    reset! # a new browser has no pending body cookie
    get confirmation_url
    expect(account.reload.confirmed?).to be false
    post confirmation_url, params: choose_password, headers: origin
    expect(account.reload.confirmed?).to be true
    expect(pending.reload.claimed_at).to be_nil
    expect {
      login(account)
    }.to change(account.draft_info_requests, :count).by(1)
    expect(ActionMailer::Base.deliveries.size).to eq(1)
  end

  it 'rejects expired confirmation and pending bodies' do
    account = FactoryBot.create(:unconfirmed_user, password: password)
    token = confirmation_token(account)
    pending = capture_letter
    travel 1.day + 1.second do
      post confirm_path(email_token: token), headers: origin
      expect(response).to have_http_status(:not_found)
      expect { login }.not_to change(DraftInfoRequest, :count)
    end
    expect(pending.reload.claimed_at).to be_nil
  end

  it 'persists a signed-in composition and returns to its owned ID after expiry' do
    login
    get new_alaveteli_pro_info_request_path(public_body: authority.url_name,
                                            subject: 'Invented budget',
                                            step: 'write')
    draft = user.draft_info_requests.first
    expect(draft).to be_present
    expect(response).to redirect_to(new_alaveteli_pro_info_request_path(
                                      draft_id: draft.id, step: 'write'
                                    ))
    travel 3.hours + 1.second do
      target = new_alaveteli_pro_info_request_path(draft_id: draft.id)
      get target
      expect(response).to redirect_to(signin_path(r: target))
      expect(AuthenticationReturn.count).to eq(0)
      login(return_to: target)
      expect(response).to redirect_to(target)
    end
  end

  it 'does not expose a draft after logout or account switch' do
    draft = FactoryBot.create(:draft_info_request,
                              user: user,
                              body: 'Invented secret draft')
    login
    delete signout_path, headers: origin
    target = new_alaveteli_pro_info_request_path(draft_id: draft.id)
    get target
    expect(response).to redirect_to(signin_path(r: target))
    other = FactoryBot.create(:user, password: password)
    login(other, return_to: target)
    follow_redirect!
    expect(response).to have_http_status(:not_found)
    expect(response.body).not_to include('Invented secret draft')
    get alaveteli_pro_info_requests_path
    expect(response.body).not_to include('Invented secret draft')
  end

  it 'changes email only after authenticated step-up and consumes the action once' do
    login
    post signchangeemail_path,
      params: { signchangeemail: { new_email: 'new-owner@example.test',
                                   password: password } }, headers: origin
    expect(response).to have_http_status(:ok)
    messages = ActionMailer::Base.deliveries
    expect(messages.map(&:to)).to contain_exactly([user.email],
      ['new-owner@example.test'])
    url = messages.find { |m|
      m.to == ['new-owner@example.test']
    }.body.decoded.
      match(%r{https?://[^\s<]+/profile/change_email/confirm/[^\s<]+})[0]
    path = URI(url).path
    get path
    expect(user.reload.email).not_to eq('new-owner@example.test')
    post path, params: { signchangeemail: { password: 'wrong-password' } },
               headers: origin
    expect(response).to have_http_status(422)
    post path, params: { signchangeemail: { password: password } },
               headers: origin
    expect(response).to redirect_to(signin_path)
    expect(user.reload.email).to eq('new-owner@example.test')
    expect(request.env['warden'].user(scope: :user)).to be_nil
    login
    post path, params: { signchangeemail: { password: password } },
               headers: origin
    expect(response).to have_http_status(:not_found)
  end

  it 'invalidates existing sessions on account closure' do
    login
    user.close!
    get show_user_profile_path(user.url_name)
    expect(response).to have_http_status(:not_found)
    login
    expect(response).to have_http_status(422)
  end

  it 'retains the existing suspended-account resource restrictions' do
    user.update!(ban_text: 'Invented suspension')
    login
    expect(response).to have_http_status(:see_other)
    get show_user_profile_path(user.url_name)
    expect(response).to have_http_status(:not_found)
    get new_alaveteli_pro_info_request_path
    expect(response).to have_http_status(:ok)
    expect(response.body).to include('Invented suspension')
  end
end
