# The Pro and pro_admin roles are retired: the inbox is available to every
# account, and there is one admin level. pro_admin always required admin,
# so this refuses to run if any pro_admin lacks the admin role: nobody may
# lose admin. Announcements for pro_admins go to admins.
#
# The down recreates both roles and gives every account but the internal
# admin the Pro role so a code rollback finds what it expects.
class RemoveProRoles < ActiveRecord::Migration[8.1]
  class AdminWouldBeLost < StandardError; end

  def up
    lacking = select_value(<<~SQL).to_i
      SELECT COUNT(DISTINCT users_roles.user_id) FROM users_roles
      JOIN roles ON roles.id = users_roles.role_id
      WHERE roles.name = 'pro_admin'
      AND NOT EXISTS (
        SELECT 1 FROM users_roles admin_roles
        JOIN roles admin ON admin.id = admin_roles.role_id
        WHERE admin_roles.user_id = users_roles.user_id
        AND admin.name = 'admin'
      )
    SQL
    if lacking.positive?
      raise AdminWouldBeLost,
            "#{lacking} pro_admin account(s) don't have the admin role. " \
            'Give them the admin role, or take pro_admin away, then run ' \
            'the migration again.'
    end

    execute "UPDATE announcements SET visibility = 'admin' " \
            "WHERE visibility = 'pro_admin'"
    execute 'DELETE FROM users_roles WHERE role_id IN ' \
            "(SELECT id FROM roles WHERE name IN ('pro', 'pro_admin'))"
    execute "DELETE FROM roles WHERE name IN ('pro', 'pro_admin')"
  end

  def down
    %w[pro pro_admin].each do |name|
      execute 'INSERT INTO roles (name, created_at, updated_at) ' \
              "SELECT '#{name}', NOW(), NOW() WHERE NOT EXISTS " \
              "(SELECT 1 FROM roles WHERE name = '#{name}')"
    end
    internal = connection.quote(AlaveteliConfiguration.contact_email)
    execute <<~SQL
      INSERT INTO users_roles (user_id, role_id)
      SELECT users.id, roles.id FROM users, roles
      WHERE roles.name = 'pro' AND users.email <> #{internal}
    SQL
  end
end
