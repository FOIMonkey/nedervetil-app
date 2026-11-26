class AddRequestJourneyContext < ActiveRecord::Migration[8.1]
  def change
    add_column :draft_info_requests, :selfhost_context, :jsonb, null: false, default: {}
  end
end
