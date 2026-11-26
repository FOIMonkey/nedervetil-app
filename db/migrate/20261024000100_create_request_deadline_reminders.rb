# One reminder per due date, so a double click can't send two. The reminder
# itself is an ordinary follow-up.
class CreateRequestDeadlineReminders < ActiveRecord::Migration[8.1]
  def change
    create_table :request_deadline_reminders do |t|
      t.bigint :info_request_id, null: false
      t.bigint :outgoing_message_id
      t.bigint :user_id
      t.string :stage, null: false
      t.date :due_on, null: false
      t.timestamps
    end
    add_index :request_deadline_reminders, [:info_request_id, :stage, :due_on], unique: true,
                                                                                name: 'index_request_deadline_reminders_once'
    add_foreign_key :request_deadline_reminders, :info_requests, on_delete: :cascade
    add_foreign_key :request_deadline_reminders, :outgoing_messages, on_delete: :nullify
    add_foreign_key :request_deadline_reminders, :users, on_delete: :nullify
  end
end
