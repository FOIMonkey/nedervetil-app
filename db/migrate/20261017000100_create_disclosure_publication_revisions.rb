class CreateDisclosurePublicationRevisions < ActiveRecord::Migration[8.1]
  def change
    create_table :disclosure_publication_revisions do |t|
      t.references :document, null: false, foreign_key: { to_table: :disclosure_documents, on_delete: :cascade }
      t.references :version, null: false, foreign_key: { to_table: :disclosure_versions }
      t.references :public_body, foreign_key: { on_delete: :nullify }
      t.references :approved_by, foreign_key: { to_table: :users, on_delete: :nullify }
      t.string :title, null: false
      t.text :description
      t.string :kind, null: false
      t.date :document_date
      t.date :released_on
      t.string :download_filename, null: false
      t.string :file_sha256, null: false
      t.string :metadata_sha256, null: false
      t.string :provenance, null: false
      t.datetime :created_at, null: false
      t.virtual :search_vector, type: :tsvector, stored: true,
                                as: "setweight(to_tsvector('english', coalesce(title, '')), 'A') || " \
                    "setweight(to_tsvector('english', coalesce(description, '')), 'B')"
    end
    add_index :disclosure_publication_revisions, :search_vector, using: :gin
    add_reference :disclosure_documents, :current_publication,
                  foreign_key: { to_table: :disclosure_publication_revisions, on_delete: :nullify }
  end
end
