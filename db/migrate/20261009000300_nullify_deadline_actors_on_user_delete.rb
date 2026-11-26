# The actor is kept for the record but must not stop a user being deleted (an
# admin may have acted on someone else's request), so it becomes NULL instead.
class NullifyDeadlineActorsOnUserDelete < ActiveRecord::Migration[8.1]
  def up
    %i[request_deadline_adjustments request_deadline_closures].each do |table|
      remove_foreign_key table, :users
      change_column_null table, :user_id, true
      add_foreign_key table, :users, on_delete: :nullify
    end
  end

  def down
    %i[request_deadline_adjustments request_deadline_closures].each do |table|
      if select_value("SELECT 1 FROM #{table} WHERE user_id IS NULL LIMIT 1")
        raise ActiveRecord::IrreversibleMigration,
              "#{table} has rows whose acting user was deleted; they can't be made NOT NULL again."
      end
    end
    %i[request_deadline_adjustments request_deadline_closures].each do |table|
      remove_foreign_key table, :users
      change_column_null table, :user_id, false
      add_foreign_key table, :users
    end
  end
end
