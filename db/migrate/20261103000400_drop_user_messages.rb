# User-to-user messaging was removed (see doc/FORK.md). user_messages only
# recorded when a message was sent, for rate limiting; the messages
# themselves were emailed, never stored. The down recreates the table and
# columns as they were, so a source rollback still matches the schema.
class DropUserMessages < ActiveRecord::Migration[8.1]
  def up
    drop_table :user_messages
    remove_column :users, :receive_user_messages
    remove_column :users, :user_messages_count
  end

  def down
    add_column :users, :receive_user_messages, :boolean,
               default: true, null: false
    add_column :users, :user_messages_count, :integer, default: 0, null: false

    create_table :user_messages do |t|
      t.references :user, foreign_key: true
      t.timestamps
    end
  end
end
