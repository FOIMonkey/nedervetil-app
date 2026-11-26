# Rows older than 31 days are deleted as new ones are written.
class CreateRequestLimitSends < ActiveRecord::Migration[8.1]
  def change
    create_table :request_limit_sends do |t|
      t.bigint :user_id, null: false
      t.string :kind, null: false
      t.bigint :info_request_id
      t.datetime :created_at, null: false
    end
    add_index :request_limit_sends, [:user_id, :kind, :created_at]
    add_index :request_limit_sends, :created_at
    add_foreign_key :request_limit_sends, :users, on_delete: :cascade
  end
end
