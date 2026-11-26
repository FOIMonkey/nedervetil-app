# Share-by-link (public tokens) was removed (see doc/FORK.md); the privacy
# gate had already stopped serving those links. The down restores the column
# empty, so a source rollback still matches the schema.
class RemoveInfoRequestPublicTokens < ActiveRecord::Migration[8.1]
  def up
    remove_column :info_requests, :public_token
  end

  def down
    add_column :info_requests, :public_token, :string
  end
end
