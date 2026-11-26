class DropDisclosureVersionsAndOriginal < ActiveRecord::Migration[8.1]
  def up
    remove_foreign_key :disclosure_documents, :disclosure_versions,
                       column: :published_version_id, if_exists: true
    remove_foreign_key :disclosure_documents, :disclosure_publication_revisions,
                       column: :current_publication_id, if_exists: true
    remove_foreign_key :disclosure_pages, :disclosure_versions,
                       column: :version_id, if_exists: true
    remove_foreign_key :disclosure_events, :disclosure_versions,
                       column: :version_id, if_exists: true

    remove_index :disclosure_pages, %i[version_id number], if_exists: true
    remove_column :disclosure_pages, :version_id

    execute <<~SQL.squish
      DELETE FROM active_storage_attachments
      WHERE record_type = 'Disclosures::Page'
        AND record_id IN (
          SELECT id FROM disclosure_pages WHERE document_id IS NULL
        )
    SQL
    execute <<~SQL.squish
      DELETE FROM active_storage_attachments
      WHERE record_type = 'Disclosures::Version'
    SQL
    execute <<~SQL.squish
      DELETE FROM active_storage_attachments
      WHERE record_type = 'Disclosures::Document'
        AND name = 'original'
    SQL

    execute 'DELETE FROM disclosure_pages WHERE document_id IS NULL'
    change_column_null :disclosure_pages, :document_id, false

    remove_column :disclosure_events, :version_id

    remove_index :disclosure_documents, :original_erase_after, if_exists: true
    remove_columns :disclosure_documents,
                   :published_version_id,
                   :current_publication_id,
                   :original_sha256,
                   :original_filename,
                   :original_content_type,
                   :original_byte_size,
                   :original_unavailable_reason,
                   :original_erase_after,
                   :original_erased_at

    drop_table :disclosure_publication_revisions
    drop_table :disclosure_versions
  end

  def down
    raise ActiveRecord::IrreversibleMigration
  end
end
