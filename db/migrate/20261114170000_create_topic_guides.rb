class CreateTopicGuides < ActiveRecord::Migration[8.1]
  # Its own copy of the model, so later changes to the app's can't break this.
  class TopicGuide < ApplicationRecord
    translates :title
  end

  def change
    create_table :topic_guides do |t|
      t.string :dataset_id
      t.string :topic_slug
      t.string :question_slug
      t.boolean :published, default: false, null: false
      t.timestamps
    end
    add_index :topic_guides, :dataset_id
    add_index :topic_guides, %i[topic_slug question_slug]
    # One guide per source, per question and per source on a question. The
    # columns can be null, and nulls never clash in a plain unique index.
    add_index :topic_guides,
              "COALESCE(dataset_id, ''), COALESCE(topic_slug, ''), " \
              "COALESCE(question_slug, '')",
              unique: true, name: 'index_topic_guides_one_per_subject'

    reversible do |dir|
      dir.up { TopicGuide.create_translation_table!(title: :string) }
      dir.down { TopicGuide.drop_translation_table! }
    end
  end
end
