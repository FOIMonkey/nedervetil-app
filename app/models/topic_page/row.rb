# What a topic page's holders, questions, published sources and other routes
# have in common: a place in the page's list, the nations they're for (empty
# for all), and the hash a topic file gives for them (Topics::Topic.new).
# Each column is named as the file names it.
module TopicPage::Row
  extend ActiveSupport::Concern
  include TopicChange::Recorded

  NOT_DATA = %w[id topic_page_id position created_at updated_at].freeze

  included do
    belongs_to :topic_page
    validates :position, numericality: { only_integer: true }
    validates :nations, topic_nations: true
  end

  def data
    TopicPage.as_file(attributes.except(*NOT_DATA))
  end
end
