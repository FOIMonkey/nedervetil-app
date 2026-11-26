require 'spec_helper'

RSpec.describe 'Authentication erasure' do
  let(:user) { FactoryBot.create(:user) }
  let(:other) { FactoryBot.create(:user) }

  def prepare_material(account)
    state = {}
    AuthenticationReturn.remember(state, '/help/about', user: account)
    AuthenticationEnrolment.start(state, account)
    PendingEmailChange.issue(account, 'invented-erasure-change@example.test')
    pending = PendingRequestDraft.capture(state,
                                          title: 'Invented pending',
                                          body: 'Invented pending body',
                                          public_body_id: 8001)
    pending.bind_to(account)
    account.post_redirects.create!(
      uri: '/help/about',
      token: 'invented-legacy-token',
      email_token: 'invented-legacy-email',
      post_params_yaml: { password: 'invented-old-password' }.to_yaml
    )
    account.update!(otp_secret: User.generate_otp_secret,
                    otp_required_for_login: true)
    account.generate_otp_backup_codes!
    account.save!
    account.close!
    account.update_columns(
      hashed_password: 'invented-legacy-hash',
      salt: 'invented-legacy-salt',
      login_token: 'invented-legacy-login',
      otp_secret_key: 'invented-legacy-secret',
      otp_enabled: true,
      otp_counter: 42,
      otp_last_used_at: 123,
      otp_enabled_at: Time.current,
      otp_backup_codes_generated_at: Time.current,
      reset_password_token: 'invented-reset',
      reset_password_sent_at: Time.current,
      confirmation_token: 'invented-confirmation',
      confirmation_sent_at: Time.current,
      unconfirmed_email: 'invented@example.test'
    )
    User.where(id: account.id).
      update_all("otp_backup_codes = 'invented-old-codes'")
  end

  it 'removes both credential stores and pending actions without deleting the user or draft' do
    prepare_material(user)
    AuthenticationReturn.remember({}, '/help/about', user: other)
    draft = user.draft_info_requests.new(title: 'Invented owned draft',
                                         body: 'Invented owned body',
                                         public_body_id: 8001)
    draft.save!(validate: false)
    user.reload
    id = user.id
    closed_at = user.closed_at
    version = user.authentication_version
    user.erase!(editor: other, reason: 'Invented erasure test')
    attributes = user.reload.attributes
    expect(user.id).to eq(id)
    expect(user.closed_at).to eq(closed_at)
    expect(user.authentication_version).not_to eq(version)
    expect(user.encrypted_password).to eq('')
    expect(user.hashed_password).to eq('')
    %w[salt login_token otp_secret_key otp_counter otp_last_used_at
       otp_enabled_at otp_backup_codes_generated_at otp_backup_codes
       otp_secret consumed_timestep reset_password_token reset_password_sent_at
       confirmation_token confirmation_sent_at
       unconfirmed_email].each do |column|
      expect(attributes.fetch(column)).to be_nil, column
    end
    expect(attributes.fetch('otp_enabled')).to be false
    expect(user.devise_otp_backup_codes).to eq([])
    expect(user.valid_password?('jonespassword')).to be false
    expect(user.active_for_authentication?).to be false
    expect(draft.reload.user_id).to eq(id)
    expect(draft.body).to eq('Invented owned body')
    expect(other.authentication_returns.count).to eq(1)
    %i[authentication_returns authentication_enrolments pending_email_changes
       pending_request_drafts post_redirects].each do |association|
      expect(user.public_send(association).count).to eq(0), association.to_s
    end
  end

  it 'rolls credential and pending-row removal back if erasure fails' do
    prepare_material(user)
    before = user.reload.attributes
    actions = user.pending_email_changes
    allow(user).to receive(:pending_email_changes).and_return(actions)
    allow(actions).
      to receive(:delete_all).and_raise('Invented deletion failure')
    expect do
      user.erase!(editor: other, reason: 'Invented rollback test')
    end.to raise_error('Invented deletion failure')
    expect(User.find(user.id).attributes).to eq(before)
    expect(user.authentication_returns.count).to eq(1)
    expect(user.authentication_enrolments.count).to eq(1)
    expect(user.pending_request_drafts.count).to eq(1)
    expect(user.post_redirects.count).to eq(1)
  end
end
