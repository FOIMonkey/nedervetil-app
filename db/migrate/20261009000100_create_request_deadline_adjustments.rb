# A moved response deadline is also written to the request's due date columns,
# so the overdue status, reminders and lists follow it; this table keeps the
# reason and the original dates so the change can be undone. For an internal
# review, which has no due date columns, this table is the only record.
class CreateRequestDeadlineAdjustments < ActiveRecord::Migration[8.1]
  def change
    create_table :request_deadline_adjustments do |t|
      t.bigint :info_request_id, null: false
      t.bigint :user_id, null: false
      t.string :stage, null: false
      t.bigint :basis_event_id, null: false
      t.date :due_on, null: false
      t.date :original_due_on, null: false
      t.date :original_very_overdue_on
      t.string :reason, null: false
      t.text :note
      t.datetime :cleared_at
      t.timestamps
    end
    add_index :request_deadline_adjustments, [:info_request_id, :stage, :cleared_at],
              name: 'index_request_deadline_adjustments_current'
    add_foreign_key :request_deadline_adjustments, :info_requests, on_delete: :cascade
    add_foreign_key :request_deadline_adjustments, :users
  end
end
