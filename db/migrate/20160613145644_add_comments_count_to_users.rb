class AddCommentsCountToUsers < ActiveRecord::Migration[4.2] # 3.2
  def up
    add_column :users, :comments_count, :integer, default: 0, null: false

    # Neither the removed model nor User's removed association is needed here.
    execute <<~SQL
      UPDATE users
      SET comments_count = counts.count
      FROM (
        SELECT user_id, COUNT(*) AS count
        FROM comments
        GROUP BY user_id
      ) AS counts
      WHERE users.id = counts.user_id
    SQL
  end

  def down
    remove_column :users, :comments_count
  end
end
