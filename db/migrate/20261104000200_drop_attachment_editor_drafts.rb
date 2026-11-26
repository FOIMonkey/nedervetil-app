# Editor recovery was removed (see doc/FORK.md). Its table held encrypted
# copies of unsaved editor work for 7 days, and existed only where
# EDITOR_RECOVERY_MIGRATIONS was set, so it is dropped if it exists, whatever
# it holds; the count is reported. The down recreates the table as
# db/editor_draft_migrate's two migrations made it (empty), so a source
# rollback still matches the schema. Rolling back the code doesn't need it:
# the old code runs without the table, and once the table is back it offers
# recovery again.
class DropAttachmentEditorDrafts < ActiveRecord::Migration[8.1]
  def up
    return unless table_exists?(:attachment_editor_drafts)

    count = select_value('SELECT COUNT(*) FROM attachment_editor_drafts').to_i
    say "Dropping #{count} editor recovery draft(s)" if count.positive?

    drop_table :attachment_editor_drafts
  end

  def down
    create_table :attachment_editor_drafts do |t|
      t.bigint :user_id, null: false
      t.bigint :document_id
      t.bigint :version_id
      t.bigint :foi_attachment_id
      t.bigint :parent_id
      t.string :scope_key, null: false, limit: 64
      t.string :draft_token, null: false
      t.bigint :draft_revision, null: false, default: 0
      t.string :mode, null: false
      t.string :base_sha256, null: false, limit: 64
      t.string :source_sha256, null: false, limit: 64
      t.string :context_digest, null: false, limit: 64
      t.text :encrypted_payload
      t.datetime :expires_at, null: false
      t.timestamps
    end
    add_index :attachment_editor_drafts, [:user_id, :scope_key],
              unique: true, name: 'private_editor_draft_scope'
    add_index :attachment_editor_drafts, :expires_at
    add_index :attachment_editor_drafts, :document_id
    add_index :attachment_editor_drafts, :foi_attachment_id
    add_index :attachment_editor_drafts, :parent_id
    add_index :attachment_editor_drafts, :version_id
    add_foreign_key :attachment_editor_drafts, :users, on_delete: :cascade
    add_foreign_key :attachment_editor_drafts, :disclosure_documents,
                    column: :document_id, on_delete: :cascade
    add_foreign_key :attachment_editor_drafts, :disclosure_versions,
                    column: :version_id, on_delete: :cascade
    add_foreign_key :attachment_editor_drafts, :foi_attachments,
                    on_delete: :cascade
    add_foreign_key :attachment_editor_drafts,
                    :attachment_management_revisions,
                    column: :parent_id, on_delete: :cascade
    add_check_constraint :attachment_editor_drafts,
                         '(document_id IS NOT NULL AND version_id IS NOT NULL ' \
                         'AND foi_attachment_id IS NULL AND parent_id IS NULL) ' \
                         'OR (document_id IS NULL AND version_id IS NULL ' \
                         'AND foi_attachment_id IS NOT NULL)',
                         name: 'private_editor_draft_target'
    add_check_constraint :attachment_editor_drafts,
                         "mode IN ('boxes', 'text') AND draft_revision >= 0",
                         name: 'private_editor_draft_format'
    add_check_constraint :attachment_editor_drafts,
                         'octet_length(encrypted_payload) <= 3145728',
                         name: 'private_editor_draft_size'
  end
end
