# The "About me" profile text was removed (see doc/FORK.md). The text is
# someone's own writing, so this refuses to run while any account holds some,
# even if it is only whitespace, rather than drop it unseen: what to do with
# it is decided first. Text cleared with SQL stays in those accounts' admin
# search documents until they are reindexed; with none held and the accounts
# reindexed, the search documents hold none either. The down adds the column
# back, empty; PostgreSQL adds it at the end of the table rather than where
# it was.
class RemoveAboutMeFromUsers < ActiveRecord::Migration[8.1]
  class AboutMePresent < StandardError; end

  def up
    count = select_value(
      "SELECT COUNT(*) FROM users WHERE about_me <> ''"
    ).to_i
    if count.positive?
      raise AboutMePresent,
            "#{count} account(s) have \"About me\" text. This migration " \
            'removes the column only when none do. Decide what to do with ' \
            'the text, export or clear it, reindex those accounts ' \
            '(User#reindex) so that admin search drops it, then run the ' \
            'migration again.'
    end

    remove_column :users, :about_me
  end

  def down
    add_column :users, :about_me, :text, default: '', null: false
  end
end
