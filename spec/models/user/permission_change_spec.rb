require 'spec_helper'

RSpec.describe User::PermissionChange do
  let(:user) { FactoryBot.create(:user) }

  it 'is only about the Trusted tick or the admin role' do
    expect(user.permission_changes.build(what: 'trusted', granted: true)).
      to be_valid
    expect(user.permission_changes.build(what: 'admin', granted: false)).
      to be_valid
    expect(user.permission_changes.build(what: 'confirmed_not_spam',
                                         granted: true)).not_to be_valid
  end

  describe '.record' do
    let(:admin) { FactoryBot.create(:admin_user) }

    it 'records each of the two that changed, with who changed it' do
      before = described_class.current(user)
      user.update!(trusted: true)
      user.add_role(:admin)
      described_class.record(user.reload, before, by: admin)
      expect(user.permission_changes.map { [_1.what, _1.granted] }).
        to match_array([['trusted', true], ['admin', true]])
      expect(user.permission_changes.map(&:changed_by)).to all(eq(admin))
    end

    it 'records the Trusted tick itself, not trusted? (which counts admins)' do
      admin_before = described_class.current(admin)
      described_class.record(admin, admin_before, by: admin)
      expect(admin.permission_changes).to be_empty
      expect(admin_before['trusted']).to be(false)
    end
  end
end
