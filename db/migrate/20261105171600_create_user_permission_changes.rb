# A record of each change to an account's Trusted tick or admin role, the two
# things that change what an account may do (User::PermissionChange).
class CreateUserPermissionChanges < ActiveRecord::Migration[8.1]
  def change
    create_table :user_permission_changes do |t|
      t.references :user, null: false, foreign_key: true
      t.references :changed_by, foreign_key: { to_table: :users,
                                               on_delete: :nullify }
      t.string :what, null: false
      t.boolean :granted, null: false

      t.timestamps
    end
  end
end
