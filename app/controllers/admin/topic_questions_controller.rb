# A topic's questions, each with the dataset that answers it and the holder
# to ask in each nation.
class Admin::TopicQuestionsController < Admin::TopicRowsController
  ROWS = :questions
  CREATE_FIELDS = { slug: :text }.freeze
  FIELDS = {
    position: :text, text: :text, heading: :text, note: :text,
    partial: :flag, published: :text, published_label: :text,
    keywords: :lines, nations: :nations, ask: :link, warning: :text,
    warning_title: :text, warning_text: :text, dataset: :nation_map,
    holder: :nation_map
  }.freeze
end
