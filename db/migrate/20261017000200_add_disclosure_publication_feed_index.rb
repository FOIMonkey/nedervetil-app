class AddDisclosurePublicationFeedIndex < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  def change
    add_index :disclosure_documents, %i[first_published_at public_id],
              order: { first_published_at: :desc, public_id: :desc },
              where: "state = 'published' AND first_published_at IS NOT NULL",
              name: 'index_disclosures_publication_feed', algorithm: :concurrently
  end
end
