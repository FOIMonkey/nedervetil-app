# A topic's other routes to an answer, that aren't a request here.
class Admin::TopicRoutesController < Admin::TopicRowsController
  ROWS = :routes
  FIELDS = {
    position: :text, what: :text, route: :text, to: :link, note: :text,
    nations: :nations
  }.freeze
end
