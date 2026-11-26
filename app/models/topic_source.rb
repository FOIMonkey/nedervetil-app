##
# Where a topic's records are already published (a topic file's `published:`,
# Topics::Topic::Published).
class TopicSource < ApplicationRecord
  include TopicPage::Row

  validates :label, :url, presence: true
  validates :url, topic_url: true
end
