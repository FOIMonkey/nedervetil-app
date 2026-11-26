# Where a topic's records are already published.
class Admin::TopicSourcesController < Admin::TopicRowsController
  ROWS = :sources
  FIELDS = {
    position: :text, label: :text, url: :text, note: :text,
    nations: :nations
  }.freeze
end
