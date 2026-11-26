# Profile photos were removed (see doc/FORK.md). Production has none, but this
# refuses to drop a table that holds any, so it can never destroy a photo.
# The down recreates the table as it was, so a source rollback still matches
# the schema.
class DropProfilePhotos < ActiveRecord::Migration[8.1]
  class PhotosPresent < StandardError; end

  def up
    count = select_value('SELECT COUNT(*) FROM profile_photos').to_i
    if count.positive?
      raise PhotosPresent,
            "profile_photos has #{count} row(s). This migration drops the " \
            'table only when it is empty. Export or delete the photos, then ' \
            'run the migration again.'
    end

    drop_table :profile_photos
  end

  def down
    create_table :profile_photos, id: :serial do |t|
      t.binary :data, null: false
      t.integer :user_id
      t.boolean :draft, default: false, null: false
      t.datetime :created_at, precision: nil
      t.datetime :updated_at, precision: nil
    end

    add_foreign_key :profile_photos, :users, name: 'fk_profile_photos_user'
  end
end
