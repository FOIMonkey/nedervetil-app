class IndexThemeForeignKeys < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def change
    %i[user_id applied_by_id parent_id info_request_event_id].each do |column|
      add_index :attachment_management_revisions, column, algorithm: :concurrently
    end
    add_index :request_deadline_reminders, :outgoing_message_id, algorithm: :concurrently
    add_index :disclosure_documents, :published_version_id, algorithm: :concurrently
  end
end
