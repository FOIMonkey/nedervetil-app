# Who holds a topic's records. A holder's key can be given once, so the form
# leaves it out once it has one. One a question names can't be deleted.
class Admin::TopicHoldersController < Admin::TopicRowsController
  ROWS = :holders
  FIELDS = {
    position: :text, what: :text, key: :text, who: :text, where: :text,
    note: :text, nations: :nations, to: :link, groups: :groups
  }.freeze
end
