require 'spec_helper'
require Rails.root.join('db/migrate/20261105000932_remove_pro_roles').to_s

# PostgreSQL DDL is transactional, so each example rolls back cleanly.
RSpec.describe RemoveProRoles do
  let(:migration) { described_class.new }
  let(:connection) { ActiveRecord::Base.connection }

  def migrate(direction)
    ActiveRecord::Migration.suppress_messages { migration.public_send(direction) }
  end

  def role_id(name)
    connection.select_value(
      "SELECT id FROM roles WHERE name = #{connection.quote(name)}"
    )
  end

  def grant(user, name)
    connection.execute('INSERT INTO users_roles (user_id, role_id) ' \
                       "VALUES (#{user.id}, #{role_id(name)})")
  end

  def role_names(user)
    connection.select_values(<<~SQL).sort
      SELECT roles.name FROM roles
      JOIN users_roles ON users_roles.role_id = roles.id
      WHERE users_roles.user_id = #{user.id}
    SQL
  end

  # Create the user first so saving it does not autosave the announcement
  # without a user_id.
  def announcement(visibility)
    FactoryBot.build(:announcement, visibility: visibility,
                                    user: FactoryBot.create(:user)).
      tap { |record| record.save!(validate: false) }
  end

  before { migrate(:down) unless role_id('pro') }

  it 'removes both roles and their assignments, and nobody loses admin' do
    user = FactoryBot.create(:user)
    admin = FactoryBot.create(:admin_user)
    grant(user, 'pro')
    grant(admin, 'pro_admin')
    for_pro_admins = announcement('pro_admin')

    migrate(:up)

    expect(role_id('pro')).to be_nil
    expect(role_id('pro_admin')).to be_nil
    expect(role_names(user)).to be_empty
    expect(role_names(admin)).to eq(['admin'])
    expect(for_pro_admins.reload.visibility).to eq('admin')
  end

  it 'refuses while a pro_admin lacks the admin role, and changes nothing' do
    user = FactoryBot.create(:user)
    grant(user, 'pro_admin')

    expect { migrate(:up) }.to raise_error(
      RemoveProRoles::AdminWouldBeLost, /1 pro_admin account\(s\)/
    )
    expect(role_names(user)).to include('pro_admin')
    expect(role_id('pro')).to be_present
  end

  it 'gives the Pro role back to every account but the internal admin on down' do
    migrate(:up)
    user = FactoryBot.create(:user)
    internal = User.internal_admin_user

    migrate(:down)

    expect(role_id('pro_admin')).to be_present
    expect(role_names(user)).to include('pro')
    expect(role_names(internal)).not_to include('pro')
  end
end
