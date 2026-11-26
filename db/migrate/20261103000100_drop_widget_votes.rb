# Request widgets were removed (see doc/FORK.md) and nothing reads their
# votes. The down recreates the table as it was, so a source rollback still
# matches the schema.
class DropWidgetVotes < ActiveRecord::Migration[8.1]
  def up
    drop_table :widget_votes
  end

  def down
    create_table :widget_votes, id: :serial do |t|
      t.string :cookie
      t.integer :info_request_id, null: false
      t.datetime :created_at, precision: nil, null: false
      t.datetime :updated_at, precision: nil, null: false
    end
    add_index :widget_votes, :info_request_id
  end
end
