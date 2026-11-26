class CreateAuthorityGroups < ActiveRecord::Migration[8.1]
  def change
    create_table :external_release_imports do |t|
      t.references :user, foreign_key: { on_delete: :nullify }
      t.string :filename
      t.string :state, null: false, default: 'preview'
      t.text :csv
      t.integer :rows_count, null: false, default: 0
      t.integer :added_count, null: false, default: 0
      t.integer :updated_count, null: false, default: 0
      t.integer :skipped_count, null: false, default: 0
      t.datetime :applied_at
      t.timestamps
    end

    create_table :external_releases do |t|
      t.references :public_body, null: false, index: false, foreign_key: { on_delete: :cascade }
      t.references :external_release_import, foreign_key: { on_delete: :nullify }
      t.string :title, null: false
      t.text :url, null: false
      # SHA-256 of the normalised URL: one row per authority and link, whatever its length.
      t.string :url_key, null: false
      t.date :released_on, null: false
      t.text :log_url
      t.datetime :hidden_at
      t.datetime :pinned_at
      # Set by an admin's edit; imports then leave the title and date alone.
      t.datetime :edited_at
      t.timestamps
      t.index %i[public_body_id url_key], unique: true
      # Newest first for one authority, and for a large group (scan by date until a page fills).
      t.index %i[public_body_id released_on]
      t.index :released_on
    end

    create_table :authority_group_settings do |t|
      t.references :category, null: false, index: { unique: true }, foreign_key: { on_delete: :cascade }
      t.datetime :hidden_at
      t.timestamps
    end
  end
end
