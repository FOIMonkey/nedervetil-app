# The final status is set as usual (a status_update event and
# set_described_state); this table only records that nothing more is expected.
# Any later correspondence reopens the request.
class CreateRequestDeadlineClosures < ActiveRecord::Migration[8.1]
  def change
    create_table :request_deadline_closures do |t|
      t.bigint :info_request_id, null: false
      t.bigint :user_id, null: false
      t.bigint :basis_event_id, null: false
      t.string :final_state, null: false
      t.datetime :cleared_at
      t.timestamps
    end
    add_index :request_deadline_closures, [:info_request_id, :cleared_at],
              name: 'index_request_deadline_closures_current'
    add_foreign_key :request_deadline_closures, :info_requests, on_delete: :cascade
    add_foreign_key :request_deadline_closures, :users
  end
end
