class CreateDisclosureTopicMatches < ActiveRecord::Migration[8.1]
  def up
    create_table :disclosure_topic_matches, primary_key: %i[topic publication_revision_id] do |t|
      t.string :topic, null: false
      t.references :publication_revision, null: false, index: true,
                                          foreign_key: { to_table: :disclosure_publication_revisions, on_delete: :cascade }
    end
  end

  def down
    drop_table :disclosure_topic_matches
  end
end
