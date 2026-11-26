require 'spec_helper'

RSpec.describe 'Authentication storage boundaries' do
  let(:user) { FactoryBot.create(:user) }
  let(:other) { FactoryBot.create(:user) }
  let(:authority) { FactoryBot.create(:public_body) }
  let(:browser) { {} }

  def pending
    PendingRequestDraft.capture(browser, title: 'Invented letter',
                                         body: 'Invented private body',
                                         public_body_id: authority.id)
  end

  it 'stores only allowlisted local destinations and query fields' do
    # rubocop:disable Layout/LineLength -- a URL path kept whole
    good = '/pro/info_requests/new?draft_id=42&step=write&password=bad&email_token=bad&send=1'
    # rubocop:enable Layout/LineLength
    expect(Authentication::ReturnPath.normalize(good)).
      to eq('/pro/info_requests/new?draft_id=42&step=write')
    %w[https://evil.test //evil.test /%2f%2fevil.test /%252f%252fevil.test
       /admin /sidekiq /c/token /profile/change_password/token
       /profile/change_email/confirm/token /request/../admin
       /request/test#token /request/a%0a].each do |value|
      expect(Authentication::ReturnPath.normalize(value)).to eq(Authentication::ReturnPath::DEFAULT),
        value
    end
    expect(Authentication::ReturnPath.normalize("/request/a\\evil")).to eq(Authentication::ReturnPath::DEFAULT)
    expect(Authentication::ReturnPath.normalize("/request/a\n")).to eq(Authentication::ReturnPath::DEFAULT)
    expect(
      Authentication::ReturnPath.normalize(
        '/pro/info_requests/new?draft_id=%2f%2fevil'
      )
    ).to eq('/pro/info_requests/new')
  end

  it 'does not create a return row or keep an old destination for the safe default' do
    AuthenticationReturn.remember(browser, '/profile/name/edit')
    expect do
      AuthenticationReturn.remember(browser, 'https://other.example.test/')
    end.to change(AuthenticationReturn, :count).by(-1)
    expect(browser[:authentication_return]).to be_nil
    expect(AuthenticationReturn.consume(browser, user)).
      to eq(Authentication::ReturnPath::DEFAULT)
  end

  it 'retires a superseded return atomically and rejects its copied token' do
    AuthenticationReturn.remember(browser, '/profile/name/edit', user: user)
    copied = browser.dup
    expect do
      AuthenticationReturn.remember(browser, '/help/about', user: user)
    end.not_to change(AuthenticationReturn, :count)
    expect(AuthenticationReturn.consume(copied, user)).
      to eq(Authentication::ReturnPath::DEFAULT)
    record = AuthenticationReturn.last
    allow(AuthenticationReturn).to receive(:create!).
      and_raise(ActiveRecord::RecordInvalid)
    expect do
      AuthenticationReturn.remember(browser, '/help/privacy', user: user)
    end.to raise_error(ActiveRecord::RecordInvalid)
    expect(AuthenticationReturn.exists?(record.id)).to be true
    expect(AuthenticationReturn.consume(browser, user)).to eq('/help/about')
  end

  it 'consumes a return once and rejects expired and wrong-user returns' do
    AuthenticationReturn.remember(browser, '/profile/name/edit', user: user)
    copied = browser.dup
    expect(AuthenticationReturn.consume(browser,
      other)).to eq(Authentication::ReturnPath::DEFAULT)
    expect(AuthenticationReturn.consume(copied,
      user)).to eq('/profile/name/edit')
    expect(AuthenticationReturn.consume(copied,
      user)).to eq(Authentication::ReturnPath::DEFAULT)
    AuthenticationReturn.remember(browser, '/profile/name/edit')
    travel 16.minutes do
      expect(AuthenticationReturn.consume(browser,
        user)).to eq(Authentication::ReturnPath::DEFAULT)
    end
  end

  it 'rejects another browser and a stale, reused or wrong-user draft claim' do
    record = pending
    record.bind_to(user)
    expect(PendingRequestDraft.claim({}, user)).to be_nil
    copied = browser.deep_dup
    expect(PendingRequestDraft.claim(copied, other)).to be_nil
    expect(record.reload.claimed_at).to be_nil
    token = record.transfer_token
    stranger = {}
    PendingRequestDraft.accept_transfer(stranger, token, other)
    expect(stranger).to be_empty
    PendingRequestDraft.accept_transfer(stranger, token, user)
    draft = PendingRequestDraft.claim(stranger, user)
    expect(draft.user_id).to eq(user.id)
    expect(PendingRequestDraft.claim(browser, user)).to be_nil
    PendingRequestDraft.accept_transfer(stranger, token, user)
    expect(PendingRequestDraft.claim(stranger, user)).to be_nil
  end

  it 'cannot rebind a draft or claim it after expiry' do
    record = pending
    expect(record.bind_to(user)).to be_truthy
    expect(record.bind_to(other)).to be false
    travel 31.minutes do
      expect(PendingRequestDraft.claim(browser, user)).to be_nil
    end
    expect(record.reload.claimed_at).to be_nil
  end

  it 'deletes superseded bodies and invalidates their browser and transfer claims' do
    previous = pending
    previous.bind_to(user)
    old_browser = browser.deep_dup
    transfer = {}
    PendingRequestDraft.accept_transfer(transfer, previous.transfer_token, user)
    replacement = pending
    expect(PendingRequestDraft.count).to eq(1)
    expect(PendingRequestDraft.exists?(previous.id)).to be false
    expect(previous.bind_to(user)).to be false
    expect(PendingRequestDraft.claim(old_browser, user)).to be_nil
    expect(PendingRequestDraft.claim(transfer, user)).to be_nil
    expect(replacement.intended_user_id).to be_nil
    expect(PendingRequestDraft.for_browser(browser)).to eq(replacement)
  end

  it 'rejects a claim whose body is superseded between lookup and locking' do
    previous = pending
    previous.bind_to(user)
    claiming_browser = browser.deep_dup
    allow(PendingRequestDraft).to receive(:for_browser).
      with(claiming_browser) do
        pending
        previous
      end
    result = nil
    expect do
      result = PendingRequestDraft.claim(claiming_browser, user)
    end.not_to change(DraftInfoRequest, :count)
    expect(result).to be_nil
    expect(PendingRequestDraft.count).to eq(1)
  end

  it 'replaces an expired body but preserves it if replacement fails' do
    previous = pending
    travel 31.minutes do
      expect { pending }.not_to change(PendingRequestDraft, :count)
    end
    replacement = PendingRequestDraft.for_browser(browser)
    expect(PendingRequestDraft.exists?(previous.id)).to be false
    allow(PendingRequestDraft).to receive(:create!).
      and_raise(ActiveRecord::RecordInvalid)
    expect { pending }.to raise_error(ActiveRecord::RecordInvalid)
    expect(PendingRequestDraft.exists?(replacement.id)).to be true
    expect(PendingRequestDraft.for_browser(browser)).to eq(replacement)
  end

  it 'cannot retire another browser’s pending body or remove an owned draft' do
    previous = pending
    browser[:pending_request_draft]['secret'] = 'invented-wrong-secret'
    expect { pending }.to change(PendingRequestDraft, :count).by(1)
    expect(PendingRequestDraft.exists?(previous.id)).to be true
    owned_pending = PendingRequestDraft.for_browser(browser)
    owned_pending.bind_to(user)
    copied = browser.deep_dup
    draft = PendingRequestDraft.claim(browser, user)
    browser.replace(copied)
    pending
    expect(draft.reload.body).to eq('Invented private body')
    expect(owned_pending.reload.draft_info_request).to eq(draft)
  end

  it 'cleans expired pending bodies while keeping active and owned drafts' do
    expired = pending
    expired.bind_to(user)
    draft = PendingRequestDraft.claim(browser, user)
    expired.update!(expires_at: 1.second.ago)
    active = pending
    orphan = PendingRequestDraft.capture({}, title: 'Invented old letter',
                                             body: 'Invented expired body',
                                             public_body_id: authority.id)
    orphan.update!(expires_at: 1.second.ago)
    Authentication::Cleanup.run
    expect(PendingRequestDraft.pluck(:id)).to eq([active.id])
    expect(draft.reload.body).to eq('Invented private body')
  end

  it 'does not lose incomplete content when it becomes an owned draft' do
    record = PendingRequestDraft.capture(browser, title: 'x' * 250, body: '',
                                                  public_body_id: authority.id)
    record.bind_to(user)
    draft = PendingRequestDraft.claim(browser, user)
    expect(draft.title).to eq('x' * 250)
    expect(draft).not_to be_valid
  end

  it 'invalidates email actions on credential, address or account changes and expiry' do
    raw = PendingEmailChange.issue(user, 'invented-new@example.test')
    action = PendingEmailChange.find_by_token(raw)
    expect(action.usable_for?(other)).to be false
    expect(action.usable_for?(user)).to be true
    expect(action.attributes.values).not_to include(raw, 'jonespassword')
    travel 1.day + 1.second do
      expect(action.usable_for?(user)).to be false
    end
    user.update!(password: 'changed-invented-password')
    expect(action.usable_for?(user)).to be false
  end

  it 'stops an email action once another account has its address' do
    raw = PendingEmailChange.issue(user, 'invented-new@example.test')
    action = PendingEmailChange.find_by_token(raw)
    FactoryBot.create(:user, email: 'Invented-New@example.test')
    expect(action.usable_for?(user)).to be false
    expect(action.complete(user, password: 'jonespassword', otp: '')).
      to be false
    expect(user.reload.email).not_to eq('invented-new@example.test')
  end

  it 'never accepts the legacy credential columns as a password or an OTP' do
    user.update_columns(hashed_password: BCrypt::Password.create('legacy-invented-password'),
                        encrypted_password: '', credential_reset_required: true,
                        otp_secret_key: 'legacy-invented-otp',
                        otp_enabled: true)
    expect(user.reload.valid_password?('legacy-invented-password')).to be false
    expect(user.active_for_authentication?).to be false
    expect(user.totp?).to be false
  end

  it 'encrypts new TOTP secrets and hashes recovery codes, rejecting TOTP replay' do
    user.update!(otp_secret: User.generate_otp_secret,
                 otp_required_for_login: true)
    expect(user.otp_secret_before_type_cast).not_to eq(user.otp_secret)
    code = user.current_otp
    expect(user.validate_and_consume_otp!(code)).to be_truthy
    expect(User.find(user.id).validate_and_consume_otp!(code)).to be_falsey
    codes = user.generate_otp_backup_codes!
    user.save!
    expect(user.reload.otp_backup_codes).not_to include(*codes)
    expect(user.invalidate_otp_backup_code!(codes.first)).to be true
    expect(User.find(user.id).invalidate_otp_backup_code!(codes.first)).
      to be false
  end

  it 'rotates the session state on password, email, TOTP and closure changes' do
    old = user.authentication_version
    user.update!(password: 'changed-invented-password')
    expect(user.authentication_version).not_to eq(old)
    old = user.authentication_version
    user.update!(email: 'changed@example.test')
    expect(user.authentication_version).not_to eq(old)
    old = user.authentication_version
    user.update!(otp_secret: User.generate_otp_secret,
                 otp_required_for_login: true)
    expect(user.authentication_version).not_to eq(old)
    old = user.authentication_version
    user.close!
    expect(user.authentication_version).not_to eq(old)
    expect(user.active_for_authentication?).to be false
  end
end
