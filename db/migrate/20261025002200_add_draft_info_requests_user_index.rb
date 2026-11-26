class AddDraftInfoRequestsUserIndex < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def change
    # Not the default name, so an upstream migration adding the same index can't clash.
    add_index :draft_info_requests, :user_id, name: 'selfhost_draft_info_requests_user', algorithm: :concurrently
  end
end
