class ReparentPagesAndTopicsToDocuments < ActiveRecord::Migration[8.1]
  def up
    add_column :disclosure_documents, :format, :string
    add_column :disclosure_documents, :page_count, :integer
    add_column :disclosure_documents, :render_notes, :jsonb,
               null: false, default: {}
    add_column :disclosure_documents, :hidden_content, :jsonb,
               null: false, default: []
    execute <<~SQL.squish
      UPDATE disclosure_documents
      SET format = disclosure_versions.format,
          page_count = disclosure_versions.page_count,
          render_notes = disclosure_versions.render_notes,
          hidden_content = disclosure_versions.hidden_content
      FROM disclosure_versions
      WHERE disclosure_documents.published_version_id = disclosure_versions.id
    SQL

    add_reference :disclosure_pages, :document,
                  foreign_key: { to_table: :disclosure_documents,
                                 on_delete: :cascade }
    change_column_null :disclosure_pages, :version_id, true
    add_index :disclosure_pages, %i[document_id number], unique: true
    execute <<~SQL.squish
      UPDATE disclosure_pages
      SET document_id = disclosure_documents.id
      FROM disclosure_documents
      WHERE disclosure_documents.published_version_id = disclosure_pages.version_id
    SQL

    execute <<~SQL.squish
      UPDATE active_storage_attachments
      SET record_type = 'Disclosures::Document',
          record_id = disclosure_documents.id
      FROM disclosure_documents
      WHERE active_storage_attachments.record_type = 'Disclosures::Version'
        AND active_storage_attachments.name = 'thumbnail'
        AND active_storage_attachments.record_id = disclosure_documents.published_version_id
        AND NOT EXISTS (
          SELECT 1
          FROM active_storage_attachments existing
          WHERE existing.record_type = 'Disclosures::Document'
            AND existing.record_id = disclosure_documents.id
            AND existing.name = 'thumbnail'
        )
    SQL

    execute <<~SQL.squish
      UPDATE active_storage_attachments AS attachment_file
      SET blob_id = version_file.blob_id
      FROM disclosure_documents dd
      INNER JOIN active_storage_attachments version_file
        ON version_file.record_type = 'Disclosures::Version'
        AND version_file.name = 'file'
        AND version_file.record_id = dd.published_version_id
      WHERE dd.state = 'published'
        AND dd.erased_at IS NULL
        AND dd.foi_attachment_id IS NOT NULL
        AND attachment_file.record_type = 'FoiAttachment'
        AND attachment_file.name = 'file'
        AND attachment_file.record_id = dd.foi_attachment_id
        AND attachment_file.blob_id <> version_file.blob_id
    SQL

    execute <<~SQL.squish
      UPDATE active_storage_attachments AS version_file
      SET record_type = 'FoiAttachment',
          record_id = dd.foi_attachment_id
      FROM disclosure_documents dd
      WHERE dd.state = 'published'
        AND dd.erased_at IS NULL
        AND dd.foi_attachment_id IS NOT NULL
        AND version_file.record_type = 'Disclosures::Version'
        AND version_file.name = 'file'
        AND version_file.record_id = dd.published_version_id
        AND NOT EXISTS (
          SELECT 1
          FROM active_storage_attachments existing
          WHERE existing.record_type = 'FoiAttachment'
            AND existing.record_id = dd.foi_attachment_id
            AND existing.name = 'file'
        )
    SQL

    execute <<~SQL.squish
      DELETE FROM active_storage_attachments version_file
      USING disclosure_documents dd
      WHERE dd.state = 'published'
        AND dd.erased_at IS NULL
        AND dd.foi_attachment_id IS NOT NULL
        AND version_file.record_type = 'Disclosures::Version'
        AND version_file.name = 'file'
        AND version_file.record_id = dd.published_version_id
        AND EXISTS (
          SELECT 1
          FROM active_storage_attachments existing
          WHERE existing.record_type = 'FoiAttachment'
            AND existing.record_id = dd.foi_attachment_id
            AND existing.name = 'file'
            AND existing.blob_id = version_file.blob_id
        )
    SQL

    sync_published_attachment_metadata!

    topic_rows = select_rows(<<~SQL.squish)
      SELECT DISTINCT dtm.topic, dd.id
      FROM disclosure_topic_matches dtm
      INNER JOIN disclosure_documents dd
        ON dd.current_publication_id = dtm.publication_revision_id
    SQL

    drop_table :disclosure_topic_matches
    create_table :disclosure_topic_matches,
                 primary_key: %i[topic document_id] do |t|
      t.string :topic, null: false
      t.references :document,
                   null: false,
                   index: true,
                   foreign_key: { to_table: :disclosure_documents,
                                  on_delete: :cascade }
    end

    insert_topic = 'INSERT INTO disclosure_topic_matches ' \
                   '(topic, document_id) VALUES (?, ?) ON CONFLICT DO NOTHING'
    topic_rows.each do |topic, document_id|
      sql = ActiveRecord::Base.sanitize_sql_array(
        [insert_topic, topic, document_id]
      )
      execute(sql)
    end
  end

  def down
    drop_table :disclosure_topic_matches
    create_table :disclosure_topic_matches,
                 primary_key: %i[topic publication_revision_id] do |t|
      t.string :topic, null: false
      t.references :publication_revision,
                   null: false,
                   index: true,
                   foreign_key: { to_table: :disclosure_publication_revisions,
                                  on_delete: :cascade }
    end

    remove_index :disclosure_pages, %i[document_id number]
    remove_reference :disclosure_pages, :document,
                     foreign_key: { to_table: :disclosure_documents }
    change_column_null :disclosure_pages, :version_id, false

    remove_column :disclosure_documents, :hidden_content
    remove_column :disclosure_documents, :render_notes
    remove_column :disclosure_documents, :page_count
    remove_column :disclosure_documents, :format
  end

  private

  def sync_published_attachment_metadata!
    dv_filename = if column_exists?(:disclosure_versions, :filename)
                    "NULLIF(dv.filename, '')"
                  else
                    'NULL'
                  end
    dv_type = if column_exists?(:disclosure_versions, :content_type)
                "NULLIF(dv.content_type, '')"
              else
                'NULL'
              end
    dv_size = if column_exists?(:disclosure_versions, :byte_size)
                'dv.byte_size'
              else
                'NULL'
              end

    rows = select_rows(<<~SQL.squish)
      SELECT fa.id,
             COALESCE(#{dv_filename}, NULLIF(b.filename, ''), fa.filename),
             COALESCE(#{dv_type}, NULLIF(b.content_type, ''), fa.content_type),
             COALESCE(b.byte_size, #{dv_size}),
             fa.filename,
             fa.content_type,
             fa.display_size
      FROM disclosure_documents dd
      INNER JOIN disclosure_versions dv
        ON dv.id = dd.published_version_id
      INNER JOIN foi_attachments fa
        ON fa.id = dd.foi_attachment_id
      INNER JOIN active_storage_attachments af
        ON af.record_type = 'FoiAttachment'
        AND af.name = 'file'
        AND af.record_id = fa.id
      INNER JOIN active_storage_blobs b
        ON b.id = af.blob_id
      WHERE dd.state = 'published'
        AND dd.erased_at IS NULL
        AND dd.foi_attachment_id IS NOT NULL
    SQL

    update_sql = <<~SQL.squish
      UPDATE foi_attachments
      SET filename = ?,
          content_type = ?,
          display_size = ?
      WHERE id = ?
    SQL

    rows.each do |id, filename, content_type, byte_size,
                  old_filename, old_content_type, old_display_size|
      display_size = if byte_size.nil?
                       old_display_size
                     else
                       format_display_size(byte_size)
                     end
      next if filename == old_filename &&
              content_type == old_content_type &&
              display_size == old_display_size

      execute(ActiveRecord::Base.sanitize_sql_array(
                [update_sql, filename, content_type, display_size, id]
              ))
    end
  end

  def format_display_size(byte_size)
    bytes = byte_size.to_i
    if bytes > 1024 * 1024
      format('%.1fM', bytes.to_f / 1024 / 1024)
    else
      "#{bytes / 1024}K"
    end
  end
end
