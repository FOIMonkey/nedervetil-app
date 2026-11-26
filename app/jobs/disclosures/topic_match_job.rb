module Disclosures
  # Matches the approved documents against the topics' search words again
  # (TopicMatch.rebuild). TopicPage queues it when a topic comes or goes or
  # its words change.
  class TopicMatchJob < ApplicationJob
    queue_as :low

    def perform
      TopicMatch.rebuild
    end
  end
end
