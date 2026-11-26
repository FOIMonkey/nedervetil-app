# Search runs on PostgreSQL alone, so Xapian's queue of index updates goes.
class DropActsAsXapianJobs < ActiveRecord::Migration[8.1]
  def change
    drop_table :acts_as_xapian_jobs do |t|
      t.string :model, null: false
      t.integer :model_id, null: false
      t.string :action, null: false
      t.timestamps null: true
      t.index [:model, :model_id], unique: true
    end
  end
end
