##
# A way to an answer that isn't a request here (a topic file's `elsewhere:`,
# Topics::Topic::Elsewhere): records about you, a complaint, or a request on
# the other FOI site.
class TopicRoute < ApplicationRecord
  include TopicPage::Row

  validates :what, :route, presence: true
  validates :to, topic_link: true
end
