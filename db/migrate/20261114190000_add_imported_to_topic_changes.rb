# Tells topics:import's changes from other changes no admin made (the
# console, a rake task), which the topic history labelled alike. Changes
# made before now keep the label they had.
class AddImportedToTopicChanges < ActiveRecord::Migration[8.1]
  def change
    add_column :topic_changes, :imported, :boolean, null: false,
                                                    default: false
    up_only do
      execute 'UPDATE topic_changes SET imported = TRUE WHERE user_id IS NULL'
    end
  end
end
