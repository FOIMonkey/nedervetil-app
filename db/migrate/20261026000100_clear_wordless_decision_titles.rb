# Decision titles with no word in them are stored empty (AuthorityFeeds::Decisions.title), so
# pages show the reference. This clears existing ones by the same Unicode rule in Ruby, whatever
# the database's locale, and lists each one it clears so a title can be put back.
class ClearWordlessDecisionTitles < ActiveRecord::Migration[8.1]
  WORD = /\p{L}{3}/

  def up
    cleared = select_rows('SELECT id, title FROM authority_feed_items WHERE title IS NOT NULL').reject { |_, title| title.match?(WORD) }
    cleared.each { |id, title| say "authority_feed_items #{id}: #{title.inspect}" }
    cleared.map(&:first).each_slice(1_000) { |ids| execute("UPDATE authority_feed_items SET title = NULL WHERE id IN (#{ids.join(',')})") }
  end

  def down; end
end
