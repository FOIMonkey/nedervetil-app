class DropDisclosureSourceSyncColumns < ActiveRecord::Migration[8.1]
  def up
    remove_columns :disclosure_documents,
                   :source_part_number,
                   :source_filename,
                   :source_content_type,
                   :source_hexdigest,
                   :source_sha256,
                   :source_changed_at,
                   :source_change,
                   :published_source_replaced_at,
                   :thread_attribution
  end

  def down
    raise ActiveRecord::IrreversibleMigration
  end
end
