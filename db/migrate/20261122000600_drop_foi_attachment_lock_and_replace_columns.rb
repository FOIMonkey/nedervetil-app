class DropFoiAttachmentLockAndReplaceColumns < ActiveRecord::Migration[8.1]
  def up
    if column_exists?(:foi_attachments, :replaced_at)
      execute <<~SQL.squish
        UPDATE foi_attachments
        SET black_masked = TRUE
        WHERE replaced_at IS NOT NULL
      SQL

      execute <<~SQL.squish
        UPDATE active_storage_blobs
        SET metadata = (
          CASE
            WHEN active_storage_blobs.metadata IS NULL
              OR BTRIM(active_storage_blobs.metadata) = ''
              OR BTRIM(active_storage_blobs.metadata) = 'null'
            THEN '{"manual_black_mask":true}'
            ELSE (active_storage_blobs.metadata::jsonb ||
                  '{"manual_black_mask":true}'::jsonb)::text
          END
        )
        FROM active_storage_attachments
        INNER JOIN foi_attachments
          ON foi_attachments.id = active_storage_attachments.record_id
        WHERE active_storage_attachments.blob_id = active_storage_blobs.id
          AND active_storage_attachments.record_type = 'FoiAttachment'
          AND active_storage_attachments.name = 'file'
          AND foi_attachments.replaced_at IS NOT NULL
      SQL
    end

    remove_columns :foi_attachments, :locked, :replaced_at, :replaced_reason
  end

  def down
    add_column :foi_attachments, :locked, :boolean, default: false
    add_column :foi_attachments, :replaced_at, :datetime
    add_column :foi_attachments, :replaced_reason, :string
  end
end
