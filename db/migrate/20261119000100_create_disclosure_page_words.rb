# The words of a document page, with where each is, for the box editor
# (Disclosures::PageWords). The database deletes a row with its page: pages
# are deleted in ways that skip Rails callbacks
# (Disclosures::Store.purge_pages).
class CreateDisclosurePageWords < ActiveRecord::Migration[8.1]
  def change
    create_table :disclosure_page_words do |t|
      t.references :page,
                   null: false,
                   foreign_key: { to_table: :disclosure_pages,
                                  on_delete: :cascade },
                   index: { unique: true }
      t.jsonb :words, null: false
      # The page also has pictures, whose words aren't among these.
      t.boolean :pictures, null: false, default: false
      t.datetime :created_at, null: false
    end
  end
end
