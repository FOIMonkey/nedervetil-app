module Disclosures
  # Suggests disclosure documents asynchronously (reading files can parse/mask).
  class SuggestJob < ApplicationJob
    queue_as :low

    # Retries refused mail reads briefly, then stops without alerting; the
    # documents panel re-enqueues on next view (doc/FORK.md).
    retry_on MailHandler::ReadRefused,
             wait: :polynomially_longer, attempts: 5 do |_job, error|
      Rails.logger.warn("Disclosures::SuggestJob: #{error.message}; left " \
                        'to the documents panel')
    end

    def perform(incoming_message_id)
      message = IncomingMessage.find_by(id: incoming_message_id) or return
      Suggester.new(message).run
    end
  end
end
