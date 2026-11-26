# Topic content, which a theme's topic and dataset files gave until now, in
# tables an admin edits (TopicPage and its rows, TopicDataset), with each
# change kept in topic_changes. A row's empty `nations` means every nation.
class CreateTopicPages < ActiveRecord::Migration[8.1]
  def change
    create_table :topic_pages do |t|
      t.string :slug, null: false, index: { unique: true }
      t.string :title, null: false
      t.text :summary, null: false
      t.integer :position, null: false
      t.string :search
      t.jsonb :titles, null: false, default: {}
      t.string :elsewhere_heading
      t.string :documents, array: true, null: false, default: []
      t.text :refused, array: true, null: false, default: []
      t.timestamps
    end

    create_table :topic_holders do |t|
      t.references :topic_page, null: false, foreign_key: true, index: false
      t.integer :position, null: false
      t.string :what, null: false
      t.string :key
      t.string :who, null: false
      t.string :nations, array: true, null: false, default: []
      t.string :where
      t.jsonb :to
      t.jsonb :groups, null: false, default: []
      t.text :note
      t.timestamps
      t.index %i[topic_page_id position]
    end

    create_table :topic_questions do |t|
      t.references :topic_page, null: false, foreign_key: true, index: false
      t.integer :position, null: false
      t.text :text, null: false
      t.string :slug, null: false
      t.jsonb :dataset, null: false, default: {}
      t.jsonb :holder, null: false, default: {}
      t.boolean :partial
      t.string :published
      t.string :published_label
      t.jsonb :ask
      t.string :nations, array: true, null: false, default: []
      t.text :keywords, array: true, null: false, default: []
      t.text :warning
      t.string :warning_title
      t.text :warning_text
      t.string :heading
      t.text :note
      t.timestamps
      t.index %i[topic_page_id position]
    end

    create_table :topic_sources do |t|
      t.references :topic_page, null: false, foreign_key: true, index: false
      t.integer :position, null: false
      t.string :label, null: false
      t.string :url, null: false
      t.text :note
      t.string :nations, array: true, null: false, default: []
      t.timestamps
      t.index %i[topic_page_id position]
    end

    create_table :topic_routes do |t|
      t.references :topic_page, null: false, foreign_key: true, index: false
      t.integer :position, null: false
      t.string :what, null: false
      t.text :route, null: false
      t.jsonb :to
      t.text :note
      t.string :nations, array: true, null: false, default: []
      t.timestamps
      t.index %i[topic_page_id position]
    end

    create_table :topic_datasets do |t|
      t.string :key, null: false, index: { unique: true }
      t.string :publisher, null: false
      t.string :title, null: false
      t.string :table_title
      t.text :answers
      t.string :url, null: false
      t.string :kind, null: false
      t.string :geography
      t.string :nations, array: true, null: false, default: []
      t.string :coverage
      t.string :frequency
      t.string :status, null: false
      t.string :area_url
      t.string :area_codes, array: true, null: false, default: []
      t.string :api
      t.timestamps
    end

    create_table :topic_changes do |t|
      t.references :user, foreign_key: { on_delete: :nullify }
      t.references :record, polymorphic: true, null: false
      t.string :action, null: false
      t.jsonb :changeset, null: false, default: {}
      t.datetime :created_at, null: false
    end
  end
end
