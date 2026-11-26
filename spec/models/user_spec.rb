# == Schema Information
#
# Table name: users
#
#  id                                :integer          not null, primary key
#  email                             :string           not null
#  name                              :string           not null
#  hashed_password                   :string           default(""), not null
#  salt                              :string
#  created_at                        :datetime         not null
#  updated_at                        :datetime         not null
#  email_confirmed                   :boolean          default(FALSE), not null
#  url_name                          :text             not null
#  last_daily_track_email            :datetime
#  ban_text                          :text             default(""), not null
#  locale                            :string
#  email_bounced_at                  :datetime
#  email_bounce_message              :text             default(""), not null
#  trusted                           :boolean          default(FALSE), not null
#  receive_email_alerts              :boolean          default(TRUE), not null
#  otp_enabled                       :boolean          default(FALSE), not null
#  otp_secret_key                    :string
#  otp_counter                       :integer
#  confirmed_not_spam                :boolean          default(FALSE), not null
#  info_requests_count               :integer          default(0), not null
#  request_classifications_count     :integer          default(0), not null
#  public_body_change_requests_count :integer          default(0), not null
#  info_request_batches_count        :integer          default(0), not null
#  daily_summary_hour                :integer
#  daily_summary_minute              :integer
#  closed_at                         :datetime
#  login_token                       :string
#  status_update_count               :integer          default(0), not null
#  last_sign_in_at                   :datetime
#  otp_last_used_at                  :integer
#  otp_enabled_at                    :datetime
#  otp_backup_codes_generated_at     :datetime
#  otp_backup_codes                  :text
#  encrypted_password                :string           default(""), not null
#  reset_password_token              :string
#  reset_password_sent_at            :datetime
#  confirmation_token                :string
#  confirmation_sent_at              :datetime
#  confirmed_at                      :datetime
#  unconfirmed_email                 :string
#  otp_secret                        :text
#  consumed_timestep                 :bigint
#  otp_required_for_login            :boolean          default(FALSE), not null
#  devise_otp_backup_codes           :string           default([]), not null, is an Array
#  authentication_version            :string           default(""), not null
#  credential_reset_required         :boolean          default(FALSE), not null
#

require 'spec_helper'
require 'models/user/spreadable_alerts'
require 'models/concerns/taggable'

RSpec.describe User do
  describe '#has_role?' do
    let(:user) { FactoryBot.create(:user) }

    it 'reads the roles once, and notices them changing' do
      expect(user.is_admin?).to be(false)
      user.add_role(:admin)
      expect(user.is_admin?).to be(true)
      user.remove_role(:admin)
      expect(user.is_admin?).to be(false)
      user.is_admin?
      queries = []
      counter = ->(*, payload) { queries << payload[:sql] }
      ActiveSupport::Notifications.subscribed(counter, 'sql.active_record') do
        3.times { user.is_admin? }
      end
      expect(queries).to be_empty
    end

    it 'ignores a role row left over with a resource' do
      role = Role.new(name: 'admin', resource_type: 'InfoRequest',
                      resource_id: 1)
      role.save!(validate: false)
      User.connection.execute(
        'INSERT INTO users_roles (user_id, role_id) ' \
        "VALUES (#{user.id}, #{role.id})"
      )
      expect(user.reload.is_admin?).to be(false)
      expect(User.with_role(:admin)).not_to include(user)
    end
  end

  describe '#add_role' do
    let(:user) { FactoryBot.create(:user) }

    it 'adds the role once' do
      2.times { user.add_role(:admin) }
      expect(user.reload.roles.map(&:name)).to eq(%w[admin])
    end

    it 'adds the site-wide role when only a row with a resource is left' do
      User.connection.execute('DELETE FROM users_roles')
      Role.delete_all
      Role.new(name: 'admin', resource_type: 'InfoRequest', resource_id: 1).
        save!(validate: false)
      user.add_role(:admin)
      expect(user.reload.is_admin?).to be(true)
      expect(Role.admin_role).to have_attributes(resource_type: nil,
                                                 resource_id: nil)
    end
  end

  describe '#remove_role' do
    let(:user) { FactoryBot.create(:admin_user) }

    it 'keeps the role when its last holder goes' do
      User.connection.execute(
        "DELETE FROM users_roles WHERE user_id <> #{user.id}"
      )
      expect { user.remove_role(:admin) }.not_to change(Role, :count)
      expect(user.reload.is_admin?).to be(false)
      expect(Role.admin_role.users).to be_empty
    end
  end

  describe '.with_role' do
    let!(:admin) { FactoryBot.create(:admin_user) }
    let!(:user) { FactoryBot.create(:user) }

    it 'returns users with the role' do
      expect(User.with_role(:admin)).to include(admin)
      expect(User.with_role('admin')).not_to include(user)
    end

    it 'chains onto other scopes' do
      expect(User.where(id: [admin.id, user.id]).with_role(:admin).
               order(:name).to_a).to eq([admin])
    end
  end

  describe '.with_any_role' do
    let!(:admin) { FactoryBot.create(:admin_user) }

    it 'returns users with any of the roles' do
      expect(User.with_any_role(:unknown, :admin)).to include(admin)
    end

    it 'returns each user once, even with a duplicate role row' do
      User.connection.execute(
        'INSERT INTO users_roles (user_id, role_id) ' \
        "VALUES (#{admin.id}, #{Role.admin_role.id})"
      )
      expect(User.with_any_role(:admin).where(id: admin.id).count).to eq(1)
    end
  end

  it_behaves_like 'PhaseCounts'
  it_behaves_like 'user/spreadable_alerts'
  it_behaves_like 'concerns/taggable', :user
end

RSpec.describe User, "making up the URL name" do
  before do
    @user = User.new
  end

  it 'should remove spaces, and make lower case' do
    @user.name = 'Some Name'
    @user.valid?
    expect(@user.url_name).to eq('some_name')
  end

  it 'should not allow a numeric name' do
    @user.name = '1234'
    @user.valid?
    expect(@user.url_name).to eq('user')
  end
end

RSpec.describe User, "banning the user" do
  it 'does not change the URL name' do
    user = FactoryBot.create(:user, name: 'nasty user 123')
    user.update(ban_text: 'You are banned')
    expect(user.url_name).to eq('nasty_user_123')
  end

  it 'does not change the stored name' do
    user = FactoryBot.create(:user, name: 'nasty user 123')
    user.update(ban_text: 'You are banned')
    expect(user.read_attribute(:name)).to eq('nasty user 123')
  end

  it 'appends a message to the name' do
    user = FactoryBot.build(:user, name: 'nasty user', ban_text: 'banned')
    expect(user.name).to eq('nasty user (Account suspended)')
  end
end

RSpec.describe User, "showing the name" do
  before do
    @user = User.new
    @user.name = 'Some Name '
  end

  it 'should strip whitespace' do
    expect(@user.name).to eq('Some Name')
  end

  describe 'if user has been banned' do
    before do
      @user.ban_text = "Naughty user"
    end

    it 'should show an "Account suspended" suffix' do
      expect(@user.name).to eq('Some Name (Account suspended)')
    end
  end
end

RSpec.describe User, 'when saving' do
  before do
    @user = User.new
  end

  it 'should not save without setting some parameters' do
    expect { @user.save! }.to raise_error(ActiveRecord::RecordInvalid)
  end

  it 'should not save with misformatted email' do
    @user.email = 'mousefooble'
    expect(@user).to_not be_valid
    expect(@user.errors[:email].size).to eq(1)
  end

  it 'should not allow an email address as a name' do
    @user.name = 'silly@example.com'
    @user.email = 'silly@example.com'
    expect(@user).to_not be_valid
    expect(@user.errors[:name].size).to eq(1)
  end

  it 'should not save with no password' do
    @user.password = ''
    expect(@user).to_not be_valid
    expect(@user.errors[:password].size).to eq(1)
  end

  it 'should not save with too short password' do
    @user.password = 'a' * 11
    expect(@user).to_not be_valid
    expect(@user.errors[:password].size).to eq(1)
  end

  it 'should not save with too long password' do
    @user.password = 'a' * 73
    expect(@user).to_not be_valid
    expect(@user.errors[:password].size).to eq(1)
  end

  it 'should not save with wrong password confirmation' do
    @user.password = 'a' * 12
    @user.password_confirmation = 'b' * 12
    expect(@user).to_not be_valid
    expect(@user.errors[:password_confirmation].size).to eq(1)
  end

  it 'should save with reasonable name, password and email' do
    @user.name = 'Mr. Reasonable'
    @user.password = 'insecurepassword'
    @user.password_confirmation = 'insecurepassword'
    @user.email = 'reasonable@localhost'
    @user.save!
    expect(@user).to be_valid
  end

  it 'should let you make two users with same name' do
    @user.name = 'Mr. Flobble'
    @user.password = 'insecurepassword'
    @user.email = 'flobble@localhost'
    @user.save!
    expect(@user).to be_valid

    @user2 = User.new
    @user2.name = 'Mr. Flobble'
    @user2.password = 'insecurepassword'
    @user2.email = 'flobble2@localhost'
    @user2.save!
    expect(@user2).to be_valid
  end

  it 'should not let you make two users with same email' do
    @user.name = 'Mr. Flobble'
    @user.password = 'insecurepassword'
    @user.email = 'flobble@localhost'
    @user.save!
    expect(@user).to be_valid

    @user2 = User.new
    @user2.name = 'Flobble Jr.'
    @user2.password = 'insecurepassword'
    @user2.email = 'flobble@localhost'
    expect(@user2).to_not be_valid
    expect(@user2.errors[:email].size).to eq(1)
    expect(@user2.errors[:email][0]).to eq('has already been taken')

    # should ignore case differences
    @user2.email = 'FloBBle@localhost'
    expect(@user2).to_not be_valid
    expect(@user2.errors[:email].size).to eq(1)
    expect(@user2.errors[:email][0]).to eq('has already been taken')
  end

  it 'should allow updated attributes even if old password is invalid' do
    @user.name = 'Mr. Elderly'
    @user.password = 'invalid'
    @user.email = 'elderly@localhost'
    @user.save(validate: false)

    @user = User.find_by(email: 'elderly@localhost')
    @user.name = 'Mr. Young'
    @user.email = 'young@localhost'
    @user.save!
    expect(@user).to be_valid
  end
end

RSpec.describe User, "when its URL name changes" do
  let(:user) { FactoryBot.create(:user) }
  let(:request) { FactoryBot.create(:info_request, user: user) }
  let(:request_event) { request.reload.last_event }

  it 'expires its requests when its URL name changes' do
    request
    expect(InfoRequest::ExpireJob).
      to receive(:perform_later).with(user, :info_requests)
    user.url_name = 'updated_url_name'
    user.save!
  end

  it 'leaves its requests alone when something else changes' do
    request
    expect(InfoRequest::ExpireJob).not_to receive(:perform_later)
    user.receive_email_alerts = false
    user.save!
  end
end

RSpec.describe User, 'previous names' do
  let(:user) { FactoryBot.build(:user, name: 'Robert') }

  let(:outgoing_message_1) do
    FactoryBot.build(:initial_request, from_name: 'Bobby', user: user)
  end

  let(:followup_1) do
    FactoryBot.build(:new_information_followup, from_name: 'Bob', user: user)
  end

  let(:followup_2) do
    FactoryBot.build(:new_information_followup, from_name: 'Bob', user: user)
  end

  let(:outgoing_message_2) do
    FactoryBot.build(:initial_request, from_name: 'Robert', user: user)
  end

  before do
    FactoryBot.create(:sent_event, outgoing_message: outgoing_message_1)
    FactoryBot.create(:followup_sent_event, outgoing_message: followup_1)
    FactoryBot.create(:followup_sent_event, outgoing_message: followup_2)
    FactoryBot.create(:sent_event, outgoing_message: outgoing_message_2)
  end

  describe '#previous_names' do
    it 'returns unique previous names without current name' do
      expect(user.previous_names).to include('Bobby').once # previous name
      expect(user.previous_names).to include('Bob').once # previous name
      expect(user.previous_names).to_not include('Robert') # current name
    end
  end
end

RSpec.describe User, " when making name and email address" do
  it "should generate a name and email" do
    @user = User.new
    @user.name = "Sensible User"
    @user.email = "sensible@localhost"

    expect(@user.name_and_email).to eq("Sensible User <sensible@localhost>")
  end

  it "should quote name and email with funny characters in the name" do
    @user = User.new
    @user.name = "Silly @ User"
    @user.email = "silly@localhost"

    expect(@user.name_and_email).to eq("\"Silly @ User\" <silly@localhost>")
  end
end

RSpec.describe User, "when emails have bounced" do
  it "should record bounces" do
    User.record_bounce_for_email("bob@localhost", "A bounce message")

    user = User.find_user_by_email("bob@localhost")
    expect(user.email_bounced_at).not_to be_nil
    expect(user.email_bounce_message).to eq("A bounce message")
  end

  it 'records valid UTF-8 for a bounce message with invalid UTF-8' do
    User.record_bounce_for_email("bob@localhost", "Invalid utf-8 \x96")
    user = User.find_user_by_email("bob@localhost")
    expect(user.email_bounce_message).to eq("Invalid utf-8 –")
  end
end

RSpec.describe User do
  describe '#sign_ins' do
    subject { user.sign_ins }

    context 'sort order is most recent first' do
      let(:user) { FactoryBot.create(:user) }

      let!(:sign_ins) do
        allow(AlaveteliConfiguration).
          to receive(:user_sign_in_activity_retention_days).and_return(1)
        FactoryBot.create_list(:user_sign_in, 2, user: user)
      end

      it { is_expected.to match_array(sign_ins.reverse) }
    end
  end

  describe '#locale' do
    subject { user.locale }

    context 'when the locale is set' do
      let(:user) { FactoryBot.build(:user, locale: 'fr') }
      it { is_expected.to eq('fr') }
    end

    context 'when the locale is empty' do
      let(:user) { FactoryBot.build(:user, locale: nil) }
      it { is_expected.to eq(AlaveteliLocalization.locale) }
    end
  end

  describe '#transactions' do
    it 'returns a TransactionCalculator with the default transaction set' do
      user = User.new
      expect(user.transactions).to eq(User::TransactionCalculator.new(user))
    end

    it 'returns a TransactionCalculator with a custom transaction set' do
      user = User.new
      calculator =
        User::TransactionCalculator.
          new(user, transaction_associations: [:info_requests])
      expect(user.transactions(:info_requests)).to eq(calculator)
    end
  end

  describe '#password=' do
    it 'creates a hashed password when the password is set' do
      expect(subject.encrypted_password).to eq('')
      subject.password = "a test password"
      expect(subject.encrypted_password).to be_present
    end
  end

  describe '#destroy' do
    let(:user) { FactoryBot.create(:user) }

    it 'destroys any associated info_requests' do
      info_request = FactoryBot.create(:info_request)
      info_request.user.reload.destroy
      expect(InfoRequest.where(id: info_request.id)).to be_empty
    end

    it 'destroys any associated user_info_request_sent_alerts' do
      info_request = FactoryBot.create(:info_request)
      alert = user.user_info_request_sent_alerts.build(
        info_request: info_request,
        alert_type: 'overdue_1'
      )
      user.destroy
      expect(UserInfoRequestSentAlert.where(id: alert.id)).to be_empty
    end

    it 'destroys any associated post_redirects' do
      post_redirect = PostRedirect.create(uri: '/', token: 'invented-token',
                                          email_token: 'invented-email-token',
                                          user_id: user.id)
      user.destroy
      expect(PostRedirect.where(id: post_redirect.id)).to be_empty
    end

    it 'destroys any associated public_body_change_requests' do
      change_request = FactoryBot.create(:add_body_request)
      change_request.user.destroy
      expect(PublicBodyChangeRequest.where(id: change_request.id)).
        to be_empty
    end

    it 'destroys any associated censor_rules' do
      censor_rule = FactoryBot.create(:user_censor_rule)
      censor_rule.censorable.destroy
      expect(CensorRule.user.where(censorable_id: user.id)).to be_empty
    end

    it 'destroys any associated info_request_batches' do
      info_request_batch = FactoryBot.create(:info_request_batch)
      info_request_batch.user.destroy
      expect(InfoRequestBatch.where(id: info_request_batch.id)).to be_empty
    end

    it 'destroys any associated request_classifications' do
      request_classification = FactoryBot.create(:request_classification)
      request_classification.user.destroy
      expect(RequestClassification.where(id: request_classification.id)).
        to be_empty
    end
  end

  describe '#expire_requests' do
    subject { user.expire_requests }

    let(:user) { FactoryBot.create(:user) }

    it 'expires the requests' do
      expect { subject }.
        to have_enqueued_job(InfoRequest::ExpireJob).with(user, :info_requests)
    end
  end

  describe '#banned?' do
    it 'is banned if the user has ban_text' do
      user = FactoryBot.build(:user, ban_text: 'banned')
      expect(user).to be_banned
    end

    it 'is not banned if the user has no ban_text' do
      user = FactoryBot.build(:user, ban_text: '')
      expect(user).to_not be_banned
    end
  end

  describe '#close_and_anonymise' do
    let(:user) { FactoryBot.create(:user) }

    it 'delegates to close!, anonymise! and erase! methods' do
      editor = double
      reason = double
      expect(user).to receive(:close!)
      expect(user).to receive(:anonymise!)
      expect(user).to receive(:erase!).with(editor: editor, reason: reason)
      user.close_and_anonymise(editor: editor, reason: reason)
    end
  end

  describe '#close' do
    subject { user.close }

    let(:user) { FactoryBot.build(:user) }

    context 'the update is successful' do
      before do
        expect(user).to receive(:close!).and_call_original
        subject
      end

      it { is_expected.to eq(true) }

      it 'closes the account' do
        expect(user).to be_closed
      end
    end

    context 'the update is unsuccessful' do
      before do
        expect(user).to receive(:close!).and_raise(ActiveRecord::RecordInvalid)
        subject
      end

      it { is_expected.to eq(false) }

      it 'does not close the account' do
        expect(user).not_to be_closed
      end
    end
  end

  describe '#close!' do
    subject { user.close! }

    let(:user) { FactoryBot.create(:user) }

    context 'the update is successful' do
      before { subject }

      it 'closes the account' do
        expect(user).to be_closed
      end

      it 'sets closed_at' do
        expect(user.closed_at).to be_present
      end

      it 'disables email alerts' do
        expect(user.receive_email_alerts).to eq(false)
      end

      it 'clears the login token' do
        expect(user.reload.login_token).to be_nil
      end
    end

    context 'the update is unsuccessful' do
      before do
        expect(user).to receive(:update!).and_raise(ActiveRecord::RecordInvalid)
      end

      it 'raises an ActiveRecord::RecordInvalid error' do
        expect { subject }.to raise_error(ActiveRecord::RecordInvalid)
      end
    end
  end

  describe '#closed?' do
    let(:user) { FactoryBot.build(:user) }

    it 'should be closed if closed_at present' do
      user.closed_at = Time.zone.now
      expect(user).to be_closed
    end

    it 'should not be closed if closed_at not present' do
      user.closed_at = nil
      expect(user).to_not be_closed
    end
  end

  describe '#erase' do
    subject { user.erase(editor: editor, reason: reason) }

    let(:editor) { instance_double(User) }
    let(:reason) { 'GDPR' }
    let(:user) { FactoryBot.build(:user) }

    context 'the update is successful' do
      before do
        user.close!
        expect(user).to receive(:erase!).
          with(editor: editor, reason: reason).and_call_original
        subject
      end

      it { is_expected.to eq(true) }

      it 'erases the account' do
        expect(user.name).to match(/Name Removed/)
      end
    end

    context 'the update is unsuccessful' do
      before do
        expect(user).to receive(:erase!).
          with(editor: editor, reason: reason).
          and_raise(ActiveRecord::RecordInvalid)
        subject
      end

      it { is_expected.to eq(false) }

      it 'does not erase the account' do
        expect(user.name).not_to match(/Name Removed/)
      end
    end
  end

  describe '#erasable?' do
    it 'is true for a closed account' do
      expect(FactoryBot.build(:user, :closed)).to be_erasable
    end

    it 'is false for an open account' do
      expect(FactoryBot.build(:user)).not_to be_erasable
    end

    it 'is false for a closed account that is banned' do
      user = FactoryBot.build(:user, :closed, ban_text: 'Spam')
      expect(user).not_to be_erasable
    end
  end

  describe '#erase!' do
    subject { user.erase!(editor: editor, reason: reason) }

    let(:editor) { instance_double(User) }
    let(:reason) { 'GDPR' }

    context 'the user account is not closed' do
      let(:user) { FactoryBot.build(:user) }

      it 'raises an ActiveRecord::RecordInvalid' do
        expect { subject }.to raise_error(ActiveRecord::RecordInvalid)
      end
    end

    context 'the user account is closed but banned' do
      let(:user) { FactoryBot.build(:user, :closed, ban_text: 'Spam') }

      it 'raises an ActiveRecord::RecordInvalid' do
        expect { subject }.to raise_error(ActiveRecord::RecordInvalid)
        expect(user.name).not_to match(/Name Removed/)
      end
    end

    context 'the update is successful' do
      let(:user) { FactoryBot.build(:user, :closed) }

      let!(:outgoing_message) do
        FactoryBot.create(:initial_request, user: user)
      end

      before do
        allow(AlaveteliConfiguration).
          to receive(:user_sign_in_activity_retention_days).and_return(1)
        FactoryBot.create(:user_sign_in, user: user)
        FactoryBot.create(:user_email_history, user: user)
        user.permission_changes.create!(what: 'trusted', granted: true)

        allow(Digest::SHA1).to receive(:hexdigest).and_return('a1b2c3d4')
        allow(MySociety::Util).
          to receive(:generate_token).and_return('r@nd0m-pa$$w0rd')

        subject

        user.reload
        outgoing_message.reload
      end

      it 'erases the name' do
        # #name currently appends "(Account suspended)". Here we specifically
        # only care about the data we hold.
        expect(user.read_attribute(:name)).to eq('[Name Removed]')
      end

      it 'erases the url_name' do
        expect(user.url_name).to eq('a1b2c3d4')
      end

      it 'erases the email' do
        expect(user.email).to eq('a1b2c3d4@invalid')
      end

      it 'erases the password' do
        expect(user.password).to be_nil
        expect(user.encrypted_password).to be_empty
      end

      it 'erases outgoing_message the from_name' do
        expect(outgoing_message.from_name).to eq('[Name Removed]')
      end

      it 'destroys any old slugs' do
        # update in the method will create a new slug as the name is changed.
        expect(user.slugs.pluck(:slug)).to eq(['a1b2c3d4'])
      end

      it 'destroys any sign_ins' do
        expect(user.sign_ins).to be_empty
      end

      it 'destroys any email_histories' do
        expect(user.email_histories).to be_empty
      end

      it 'destroys any permission changes' do
        expect(user.permission_changes).to be_empty
      end
    end

    context 'the update is unsuccessful' do
      let(:user) { FactoryBot.build(:user, :closed) }

      before do
        expect(user).to receive(:update!).and_raise(ActiveRecord::RecordInvalid)
      end

      it 'raises an ActiveRecord::RecordInvalid error' do
        expect { subject }.to raise_error(ActiveRecord::RecordInvalid)
      end
    end
  end

  describe '#erase_later' do
    subject { user.erase_later(editor: editor, reason: reason) }

    let(:user) { FactoryBot.create(:user) }
    let(:editor) { FactoryBot.create(:admin_user) }
    let(:reason) { 'GDPR' }

    it 'enqueues a User::ErasureJob' do
      expect { subject }.
        to have_enqueued_job(User::ErasureJob).
        with(user, editor: editor, reason: reason)
    end
  end

  describe '#anonymise!' do
    subject { user.anonymise! }

    let(:user) { FactoryBot.build(:user, name: 'Bob Smith') }

    context 'when the user has info requests' do
      before { FactoryBot.create(:info_request, user: user) }

      it 'creates a regexp censor rule for user name' do
        subject
        expected_text =
          User::Anonymisable::NamePattern.new('Bob Smith').to_censor_rule_text
        censor_rule = user.censor_rules.find { _1.text == expected_text }
        expect(censor_rule).to_not be_nil
        expect(censor_rule.replacement).to eq('[Name Removed]')
        expect(censor_rule.regexp).to eq(true)
        expect(censor_rule.case_sensitive).to eq(false)
        expect(censor_rule.last_edit_editor).to eq('User#anonymise!')
        expect(censor_rule.last_edit_comment).to eq('User#anonymise!')
      end
    end

    context 'when the user has info requests that use a different name' do
      let(:previous_name) { 'Bob' }

      before do
        FactoryBot.create(:info_request, user: user)
        FactoryBot.create(
          :new_information_followup, user: user, from_name: previous_name
        )
      end

      it 'creates a regexp censor rule for previous names' do
        subject
        expected_text =
          User::Anonymisable::NamePattern.new(previous_name).to_censor_rule_text
        censor_rule = user.censor_rules.find { _1.text == expected_text }
        expect(censor_rule).to_not be_nil
        expect(censor_rule.regexp).to eq(true)
        expect(censor_rule.replacement).to eq('[Name Removed]')
        expect(censor_rule.last_edit_editor).to eq('User#anonymise!')
        expect(censor_rule.last_edit_comment).to eq('User#anonymise!')
      end
    end

    context 'when the user has no info requests' do
      it 'does not create a censor rule' do
        subject
        expect(user.censor_rules).to be_empty
      end
    end

    context 'when NamePattern.pattern is customised' do
      around do |example|
        original = User::Anonymisable::NamePattern.pattern
        User::Anonymisable::NamePattern.pattern = '(?i)%{firstname}'
        example.run
        User::Anonymisable::NamePattern.pattern = original
      end

      before { FactoryBot.create(:info_request, user: user) }

      it 'uses the custom regexp pattern' do
        subject
        censor_rule = user.censor_rules.find { _1.text == '(?i)Bob' }
        expect(censor_rule).to_not be_nil
        expect(censor_rule.regexp).to eq(true)
      end
    end
  end

  describe '.closed' do
    it 'should not return users with closed_at timestamp' do
      active_user = FactoryBot.create(:user)
      user = FactoryBot.create(:user, closed_at: Time.zone.now)
      expect(User.closed).to_not include(active_user)
      expect(User.closed).to include(user)
    end
  end

  describe '.not_closed' do
    it 'should return users with closed_at timestamp' do
      active_user = FactoryBot.create(:user)
      user = FactoryBot.create(:user, closed_at: Time.zone.now)
      expect(User.not_closed).to include(active_user)
      expect(User.not_closed).to_not include(user)
    end
  end

  describe '#active?' do
    let(:user) { FactoryBot.build(:user) }

    it 'should be active if not banned and not closed' do
      allow(user).to receive(:banned?).and_return(false)
      allow(user).to receive(:closed?).and_return(false)
      expect(user).to be_active
    end

    it 'should not be active if banned' do
      allow(user).to receive(:banned?).and_return(true)
      expect(user).to_not be_active
    end

    it 'should not be active if closed' do
      allow(user).to receive(:closed?).and_return(true)
      expect(user).to_not be_active
    end
  end

  describe '#suspended?' do
    let(:user) { FactoryBot.build(:user) }

    it 'should not be suspended if not banned and not closed' do
      allow(user).to receive(:banned?).and_return(false)
      allow(user).to receive(:closed?).and_return(false)
      expect(user).to_not be_suspended
    end

    it 'should be suspended if banned' do
      allow(user).to receive(:banned?).and_return(true)
      expect(user).to be_suspended
    end

    it 'should be suspended if closed' do
      allow(user).to receive(:closed?).and_return(true)
      expect(user).to be_suspended
    end
  end

  describe '#prominence' do
    subject { user.prominence }

    context 'when the user is banned' do
      let(:user) { FactoryBot.build(:user, :banned) }
      it { is_expected.to eq('hidden') }
    end

    context 'when the user is banned and closed' do
      let(:user) { FactoryBot.build(:user, :banned, :closed) }
      it { is_expected.to eq('hidden') }
    end

    context 'when the user is closed' do
      let(:user) { FactoryBot.build(:user, :closed) }
      it { is_expected.to eq('normal') }
    end

    context 'when the user is unconfirmed' do
      let(:user) { FactoryBot.build(:user, :unconfirmed) }
      it { is_expected.to eq('normal') }
    end

    context 'in normal circumstances' do
      let(:user) { FactoryBot.build(:user) }
      it { is_expected.to eq('normal') }
    end
  end

  describe '.active' do
    it 'should not return banned users' do
      active_user = FactoryBot.create(:user)
      user = FactoryBot.create(:user, ban_text: 'banned')
      expect(User.active).to include(active_user)
      expect(User.active).to_not include(user)
    end

    it 'should not return closed users' do
      active_user = FactoryBot.create(:user)
      user = FactoryBot.create(:user, closed_at: Time.zone.now)
      expect(User.active).to include(active_user)
      expect(User.active).to_not include(user)
    end
  end

  describe '.banned' do
    it 'should return banned users' do
      active_user = FactoryBot.create(:user)
      user = FactoryBot.create(:user, ban_text: 'banned')
      expect(User.banned).to_not include(active_user)
      expect(User.banned).to include(user)
    end
  end

  describe '.not_banned' do
    it 'should not return banned users' do
      active_user = FactoryBot.create(:user)
      user = FactoryBot.create(:user, ban_text: 'banned')
      expect(User.not_banned).to include(active_user)
      expect(User.not_banned).not_to include(user)
    end
  end

  describe '.find_user_by_email' do
    it 'finds a user by email case-insensitively' do
      user = FactoryBot.create(:user)
      expect(User.find_user_by_email(user.email.upcase)).to eq(user)
    end

    it 'returns nil when passed nil' do
      expect(User.find_user_by_email(nil)).to eq(nil)
    end

    it 'returns nil when passed an empty string' do
      expect(User.find_user_by_email('')).to eq(nil)
    end

    it 'returns nil when passed a whitespace string' do
      expect(User.find_user_by_email('  ')).to eq(nil)
    end

    it 'matches a padded email' do
      user = FactoryBot.create(:user)
      expect(User.find_user_by_email(" #{user.email} ")).to eq(user)
    end
  end

  describe '#can_admin_roles' do
    it 'returns an array including the admin and roles for an admin user' do
      admin_user = FactoryBot.create(:admin_user)
      expect(admin_user.can_admin_roles).to eq([:admin])
    end

    it 'returns an empty array for a pro user' do
      user = FactoryBot.create(:user)
      expect(user.can_admin_roles).to eq([])
    end

    it 'returns an empty array for a user with no roles' do
      pro_user = FactoryBot.create(:pro_user)
      expect(pro_user.can_admin_roles).to eq([])
    end
  end

  describe '#can_admin_role?' do
    let(:admin_user) { FactoryBot.create(:admin_user) }
    let(:pro_user) { FactoryBot.create(:pro_user) }

    it 'returns true for an admin user and the admin role' do
      expect(admin_user.can_admin_role?(:admin)).
        to be true
    end

    it 'return false for an admin user and the pro role' do
      expect(admin_user.can_admin_role?(:pro)).
        to be false
    end

    it 'returns false for a pro user and the admin role' do
      expect(pro_user.can_admin_role?(:admin)).
        to be false
    end

    it 'returns false for a pro user and the pro role' do
      expect(pro_user.can_admin_role?(:pro)).
        to be false
    end
  end

  describe '.info_request_events' do
    let(:user) { FactoryBot.create(:user) }
    let(:info_request) { FactoryBot.create(:info_request, user: user) }
    let!(:response_event) do
      FactoryBot.create(:response_event, info_request: info_request)
    end
    let!(:status_event) do
      FactoryBot.create(:info_request_event, event_type: 'status_update',
                                             info_request: info_request)
    end
    let!(:resent_event) do
      FactoryBot.create(:resent_event, info_request: info_request)
    end

    it "returns events in descending created_at order" do
      expect(user.info_request_events.first).to eq resent_event
      expect(user.info_request_events.second).to eq status_event
      expect(user.info_request_events.third).to eq response_event
    end

    it "returns all of the user's events" do
      # NOTE: there is a fourth "sent" event created automatically
      expect(user.info_request_events.count).to eq 4
    end
  end

  describe 'notifications' do
    it 'deletes associated notifications when destroyed' do
      notification = FactoryBot.create(:notification)
      user = notification.user.reload
      expect(Notification.where(id: notification.id)).to exist
      user.destroy
      expect(Notification.where(id: notification.id)).not_to exist
    end
  end

  describe '#active_admin?' do
    subject { user.active_admin? }

    context 'when the user has no roles' do
      let(:user) { FactoryBot.create(:user) }
      it { is_expected.to eq(false) }
    end

    context 'when the user is a pro' do
      let(:user) { FactoryBot.create(:pro_user) }
      it { is_expected.to eq(false) }
    end

    context 'when the user is an admin' do
      let(:user) { FactoryBot.create(:admin_user) }
      it { is_expected.to eq(true) }
    end

    context 'when the user is a suspended admin' do
      let(:user) { FactoryBot.create(:admin_user, :banned) }
      it { is_expected.to eq(false) }
    end

    context 'when the user is a closed admin' do
      let(:user) { FactoryBot.create(:admin_user, :closed) }
      it { is_expected.to eq(false) }
    end
  end

  describe '#next_daily_summary_time' do
    let(:user) do
      FactoryBot.create(:user, daily_summary_hour: 7,
                               daily_summary_minute: 56)
    end

    context "when the time is in the future" do
      let(:expected_time) { Time.zone.now.change(hour: 7, min: 56) }

      it "returns today's date with the daily summary time set" do
        travel_to(expected_time - 1.minute) do
          expect(user.next_daily_summary_time).
            to be_within(1.second).of(expected_time)
        end
      end
    end

    context "when the time is in the past" do
      let(:expected_time) { Time.zone.now.change(hour: 7, min: 56) + 1.day }

      it "returns tomorrow's date with the daily summary time set" do
        travel_to(Time.zone.now.change(hour: 7, min: 57)) do
          expect(user.next_daily_summary_time).
            to be_within(1.second).of(expected_time)
        end
      end
    end
  end

  describe '#notification_frequency' do
    let(:user) { FactoryBot.create(:user) }

    context 'when the user has not opted into instant mail' do
      it 'returns Notification::DAILY' do
        expect(user.notification_frequency).to eq(Notification::DAILY)
      end
    end

    context 'when the user has opted into instant mail' do
      before { IncomingAttention::InstantEmails.set!(user, true) }

      it 'returns Notification::INSTANTLY' do
        expect(user.notification_frequency).to eq(Notification::INSTANTLY)
      end
    end
  end

  describe "#notify" do
    let(:info_request_event) { FactoryBot.create(:response_event) }
    let(:user) { info_request_event.info_request.user }

    it "creates a notification" do
      expect { user.notify(info_request_event) }.
        to change { Notification.count }.by 1
    end

    it "calls notification_frequency" do
      expect(user).to receive(:notification_frequency)
      user.notify(info_request_event)
    end
  end

  describe '#features' do
    let(:user) { FactoryBot.build(:user) }

    it 'delegates to AlaveteliFeatures' do
      features = double(:features)
      expect(AlaveteliFeatures).to receive(:features).and_return(features)
      expect(features).to receive(:with_actor).with(user)
      user.features
    end
  end

  describe '#features=' do
    let(:user) { FactoryBot.build(:user) }

    it 'enables features' do
      features = double(:features)
      allow(user).to receive(:features).and_return(features)
      expect(features).to receive(:assign_features).with([:new_feature])
      user.features = [:new_feature]
    end
  end

  describe "#flipper_id" do
    let(:user) { FactoryBot.create(:user) }

    it "returns the user's id, prefixed with the class name" do
      expect(user.flipper_id).to eq("User;#{user.id}")
    end
  end

  describe 'role callbacks' do
    let(:user) { FactoryBot.build(:user) }

    context 'adding a role' do
      it 'enables user role features' do
        features = double(:features)
        allow(user).to receive(:features).and_return(features)
        expect(features).to receive(:assign_role_features)
        user.add_role(:admin)
      end
    end

    context 'removing a role' do
      let(:user) { FactoryBot.create(:admin_user) }

      it 'updates user role features' do
        features = double(:features)
        allow(user).to receive(:features).and_return(features)
        expect(features).to receive(:assign_role_features)
        user.remove_role(:admin)
      end
    end

    context 'adding unknown role' do
      it 'raises and adds nothing' do
        expect { user.add_role(:unknown) }.
          to raise_error(ActiveRecord::RecordInvalid)
        expect(user.roles).to be_empty
      end
    end
  end

  describe '#trusted?' do
    subject { user.trusted? }

    let(:user) { FactoryBot.build(:user) }
    it { is_expected.to eq(false) }

    context 'when an admin has ticked Trusted' do
      let(:user) { FactoryBot.build(:user, trusted: true) }
      it { is_expected.to eq(true) }
    end

    context 'when the user is an admin' do
      let(:user) { FactoryBot.create(:admin_user) }
      it { is_expected.to eq(true) }
    end

    # An admin's powers need an active account (User#active_admin?).
    context 'when the user is a suspended admin' do
      let(:user) { FactoryBot.create(:admin_user, ban_text: 'Suspended') }
      it { is_expected.to eq(false) }
    end

    context 'when the user is the internal admin account' do
      let(:user) { User.internal_admin_user }
      it { is_expected.to eq(true) }
    end

    # The themes' specs still use the column's old name.
    it 'still accepts no_limit, the old name, for writing only' do
      user = FactoryBot.build(:user, no_limit: true)
      expect(user.trusted?).to eq(true)
      expect(user).not_to respond_to(:no_limit)
      expect(user).not_to respond_to(:no_limit?)
    end
  end

  describe '#record_sign_in' do
    let(:user) { FactoryBot.create(:user) }

    let(:ip) { '192.168.1.1' }
    let(:user_agent) { 'Mozilla/5.0' }

    context 'when retaining sign ins is enabled' do
      before do
        allow(AlaveteliConfiguration).
          to receive(:user_sign_in_activity_retention_days).and_return(1)
      end

      it 'creates sign_in instance with given arguments' do
        expect {
          user.record_sign_in(ip: ip, user_agent: user_agent)
        }.to change { user.sign_ins.count }.by(1)

        sign_in = user.sign_ins.first
        expect(sign_in.ip).to eq(ip)
        expect(sign_in.user_agent).to eq(user_agent)
      end

      it 'touches last_sign_in_at' do
        expect { user.record_sign_in(ip: '192.168.1.1') }.
          to change(user, :last_sign_in_at).from(nil)
        expect(user.last_sign_in_at).to be_a(Time)
      end
    end

    context 'when retaining sign ins is disabled' do
      before do
        allow(AlaveteliConfiguration).
          to receive(:user_sign_in_activity_retention_days).and_return(0)
      end

      it 'does not create sign_in instance' do
        expect {
          user.record_sign_in(ip: ip, user_agent: user_agent)
        }.not_to(change { user.sign_ins.count })
      end

      it 'touches last_sign_in_at' do
        expect { user.record_sign_in(ip: '192.168.1.1') }.
          to change(user, :last_sign_in_at).from(nil)
        expect(user.last_sign_in_at).to be_a(Time)
      end
    end
  end
end
