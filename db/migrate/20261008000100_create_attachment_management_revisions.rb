# Confirming a draft hands it to FoiAttachment's replacement, which keeps
# the audit trail; this table records what was asked for, produced and
# checked.
class CreateAttachmentManagementRevisions < ActiveRecord::Migration[8.1]
  def change
    create_table :attachment_management_revisions do |t|
      t.bigint :foi_attachment_id, null: false
      t.bigint :user_id, null: false
      t.bigint :parent_id
      t.string :kind, null: false
      t.string :status, null: false, default: 'processing'
      t.string :source_sha256, null: false
      t.string :source_content_type, null: false
      t.text :source_filename, null: false
      t.jsonb :instructions, null: false, default: {}
      t.string :engine
      t.string :output_sha256
      t.string :output_content_type
      t.text :output_filename
      t.bigint :output_byte_size
      t.jsonb :report, null: false, default: {}
      t.text :error
      t.text :reason
      t.bigint :applied_by_id
      t.datetime :applied_at
      t.bigint :info_request_event_id
      t.timestamps
    end
    add_index :attachment_management_revisions, [:foi_attachment_id, :created_at],
              name: 'attachment_management_revisions_by_attachment'
    add_foreign_key :attachment_management_revisions, :foi_attachments, on_delete: :cascade
    add_foreign_key :attachment_management_revisions, :users
    add_foreign_key :attachment_management_revisions, :users, column: :applied_by_id
    add_foreign_key :attachment_management_revisions, :attachment_management_revisions,
                    column: :parent_id, on_delete: :nullify
    add_foreign_key :attachment_management_revisions, :info_request_events, on_delete: :nullify
  end
end
