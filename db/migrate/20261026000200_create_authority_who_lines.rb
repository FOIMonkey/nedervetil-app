# An admin's own words for what an authority does, shown for it in a group's Who does what in
# place of the line built from the topic files.
class CreateAuthorityWhoLines < ActiveRecord::Migration[8.1]
  def change
    create_table :authority_who_lines do |t|
      t.references :public_body, null: false, index: { unique: true }, foreign_key: { on_delete: :cascade }
      t.string :line, null: false
      t.timestamps
    end
  end
end
