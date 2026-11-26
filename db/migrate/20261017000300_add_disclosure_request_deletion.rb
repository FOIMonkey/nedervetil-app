# A document kept after its request was deleted (Disclosures::RequestDeletion).
class AddDisclosureRequestDeletion < ActiveRecord::Migration[8.1]
  def change
    add_reference :disclosure_documents, :owner, foreign_key: { to_table: :users, on_delete: :nullify }
    add_column :disclosure_documents, :request_deleted_at, :datetime
    # AttachmentManagement::Attribution of the thread's file, as it was when the request was deleted.
    add_column :disclosure_documents, :thread_attribution, :jsonb, null: false, default: []
  end
end
