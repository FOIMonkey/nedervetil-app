# The authority typeahead offers names like a misspelt query when full text
# finds nothing (Search::Adapters::Postgresql::SimilarNameQuery), by pg_trgm
# word similarity. pg_trgm is a trusted extension, so the app's own database
# user can create it, as with unaccent.
class AddTrigramIndexToPublicBodyNames < ActiveRecord::Migration[8.1]
  def change
    enable_extension 'pg_trgm'
    add_index :public_body_translations, :name,
              using: :gin, opclass: :gin_trgm_ops,
              name: 'index_public_body_translations_on_name_trgm'
  end
end
