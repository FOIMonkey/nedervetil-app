class AddTrackThingsCountToUsers < ActiveRecord::Migration[4.2] # 3.2
  def up
    add_column :users, :track_things_count, :integer, default: 0, null: false

    # Neither the removed model nor User's removed association is needed here.
    execute <<~SQL
      UPDATE users
      SET track_things_count = tracks.count
      FROM (
        SELECT tracking_user_id, COUNT(*) AS count
        FROM track_things
        GROUP BY tracking_user_id
      ) AS tracks
      WHERE users.id = tracks.tracking_user_id
    SQL
  end

  def down
    remove_column :users, :track_things_count
  end
end
