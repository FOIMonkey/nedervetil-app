class CreateDisclosureDocuments < ActiveRecord::Migration[8.1]
  def change
    create_table :disclosure_documents do |t|
      t.string :public_id, null: false
      # Nullified, never cascaded: provenance outlives erasure of the reply.
      t.references :info_request, foreign_key: { on_delete: :nullify }
      t.references :public_body, foreign_key: { on_delete: :nullify }
      t.references :incoming_message, foreign_key: { on_delete: :nullify }
      t.references :foi_attachment, foreign_key: { on_delete: :nullify }, index: { unique: true }
      t.references :info_request_batch, foreign_key: { on_delete: :nullify }
      t.string :source_kind, null: false
      t.integer :source_part_number
      t.string :source_filename
      t.string :source_content_type
      t.string :source_hexdigest
      # SHA-256 of the file as the thread serves it.
      t.string :source_sha256

      t.string :kind, null: false
      t.string :title, null: false
      t.text :description
      t.date :document_date
      # When the reply arrived; the document's own date can be years earlier.
      t.date :released_on

      t.string :state, null: false, default: 'draft'
      t.bigint :published_version_id
      t.datetime :first_published_at
      t.datetime :published_at
      t.references :published_by, foreign_key: { to_table: :users, on_delete: :nullify }
      t.datetime :withdrawn_at
      t.references :withdrawn_by, foreign_key: { to_table: :users, on_delete: :nullify }
      t.string :withdrawal_kind
      t.text :withdrawal_reason
      t.datetime :source_changed_at
      t.string :source_change
      t.datetime :published_source_replaced_at
      t.datetime :erased_at

      # The private copy of the file as it arrived (admins only).
      t.string :original_sha256
      t.string :original_filename
      t.string :original_content_type
      t.bigint :original_byte_size
      t.string :original_unavailable_reason
      t.datetime :original_erase_after
      t.datetime :original_erased_at

      t.references :created_by, foreign_key: { to_table: :users, on_delete: :nullify }
      t.references :updated_by, foreign_key: { to_table: :users, on_delete: :nullify }
      t.virtual :search_vector, type: :tsvector, stored: true,
                                as: "setweight(to_tsvector('english', coalesce(title, '')), 'A') || " \
                                    "setweight(to_tsvector('english', coalesce(description, '')), 'B')"
      t.timestamps
    end
    add_index :disclosure_documents, :public_id, unique: true
    add_index :disclosure_documents, [:state, :kind]
    add_index :disclosure_documents, :search_vector, using: :gin
    add_index :disclosure_documents, :original_erase_after

    create_table :disclosure_versions do |t|
      t.references :document, null: false, foreign_key: { to_table: :disclosure_documents, on_delete: :cascade }
      t.integer :number, null: false
      t.references :parent, foreign_key: { to_table: :disclosure_versions, on_delete: :nullify }
      t.string :change, null: false
      t.text :note
      t.jsonb :instructions, null: false, default: {}
      t.jsonb :report, null: false, default: {}
      t.string :status, null: false, default: 'processing'
      t.text :failure
      t.string :sha256
      t.string :content_type
      t.string :filename
      t.bigint :byte_size
      t.string :format
      t.integer :page_count
      t.string :engine
      t.jsonb :hidden_content, null: false, default: []
      t.jsonb :render_notes, null: false, default: {}
      t.string :basis_sha256
      t.datetime :restricted_at
      t.datetime :files_erased_at
      # A file made from what a reader sees, with nothing hidden.
      t.boolean :clean, null: false, default: false
      t.references :created_by, foreign_key: { to_table: :users, on_delete: :nullify }
      t.timestamps
    end
    add_index :disclosure_versions, [:document_id, :number], unique: true
    add_foreign_key :disclosure_documents, :disclosure_versions, column: :published_version_id,
                                                                 on_delete: :nullify

    create_table :disclosure_pages do |t|
      t.references :version, null: false, foreign_key: { to_table: :disclosure_versions, on_delete: :cascade }
      t.integer :number, null: false
      t.string :label
      t.string :kind, null: false
      t.text :text
      t.string :text_source
      t.string :text_note
      t.integer :width
      t.integer :height
      t.integer :rows
      t.integer :columns
      t.boolean :truncated, null: false, default: false
      # Capped: to_tsvector fails beyond 1 MB of lexemes.
      t.virtual :search_vector, type: :tsvector, stored: true,
                                as: "to_tsvector('english', left(coalesce(text, ''), 200000))"
      t.timestamps
    end
    add_index :disclosure_pages, [:version_id, :number], unique: true
    add_index :disclosure_pages, :search_vector, using: :gin

    create_table :disclosure_events do |t|
      t.references :document, null: false, foreign_key: { to_table: :disclosure_documents, on_delete: :cascade }
      t.references :version, foreign_key: { to_table: :disclosure_versions, on_delete: :nullify }
      t.references :user, foreign_key: { on_delete: :nullify }
      t.string :action, null: false
      t.jsonb :details, null: false, default: {}
      t.datetime :created_at, null: false
    end

    # Worked out in a job (reading a file can mask it); kept until the file changes.
    create_table :disclosure_suggestions do |t|
      t.references :incoming_message, null: false, foreign_key: { on_delete: :cascade }
      t.references :foi_attachment, null: false, foreign_key: { on_delete: :cascade }, index: { unique: true }
      t.string :fingerprint, null: false
      t.integer :rule_version, null: false
      t.string :suggestion, null: false
      t.string :rule
      t.string :reason
      t.boolean :confident, null: false, default: false
      t.string :display_name
      t.string :content_type
      t.bigint :byte_size
      t.timestamps
    end
  end
end
