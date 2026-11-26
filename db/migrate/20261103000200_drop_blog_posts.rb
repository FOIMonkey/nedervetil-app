# The blog was removed (see doc/FORK.md). Its posts were copies of an
# external feed, so nothing is lost here; their admin tags go with them.
# The down recreates the table as it was, so a source rollback still matches
# the schema.
class DropBlogPosts < ActiveRecord::Migration[8.1]
  def up
    execute "DELETE FROM has_tag_string_tags WHERE model_type = 'Blog::Post'"
    drop_table :blog_posts
  end

  def down
    create_table :blog_posts do |t|
      t.string :title
      t.string :url
      t.jsonb :data

      t.timestamps
    end
  end
end
