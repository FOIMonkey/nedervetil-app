# A migration adds the default feeds and links as data, so a test database built
# from structure.sql has none of them. They aren't seeds, as a deploy would
# bring back any that an admin had removed.
require Rails.root.join('db/migrate/20261023000100_create_authority_feeds')

RSpec.configure do |config|
  config.before(:suite) do
    CreateAuthorityFeeds::FEEDS.each do |row|
      AuthorityFeeds::Feed.find_or_create_by!(key: row[:key]) do |feed|
        feed.assign_attributes(row.except(:key))
      end
    end
    CreateAuthorityFeeds::LINKS.each do |row|
      AuthorityFeeds::Link.find_or_create_by!(label: row[:label]) do |link|
        link.assign_attributes(row.except(:label))
      end
    end
  end
end
