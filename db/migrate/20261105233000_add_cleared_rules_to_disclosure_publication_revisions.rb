# The masking rules an admin's clear of a rule match covered, each with when
# it was last changed, kept on the publication it let through. Takedowns
# exempt exactly those, unchanged (RuleCheck.published_match?). A clear made
# before this recorded no rules, so it exempts none.
class AddClearedRulesToDisclosurePublicationRevisions < ActiveRecord::Migration[8.1]
  def change
    add_column :disclosure_publication_revisions, :cleared_rules, :jsonb,
               default: {}, null: false
  end
end
