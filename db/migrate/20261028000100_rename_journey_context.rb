class RenameJourneyContext < ActiveRecord::Migration[8.1]
  def change
    rename_column :draft_info_requests, :selfhost_context, :journey_context
    rename_index :draft_info_requests, 'selfhost_draft_info_requests_user', 'draft_info_requests_by_user'
  end
end
