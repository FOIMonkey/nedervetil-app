# Removes Action Mailbox's InboundEmail once RawEmail has been read.
class RawEmail::ForgetInboundJob < ApplicationJob
  queue_as :low

  StillRouting = Class.new(StandardError)

  WAIT = 30.minutes

  retry_on StillRouting,
           wait: WAIT,
           attempts: (RequestMailbox::ROUTE_AGAIN_FOR / WAIT) + 2 do |job, _|
    Rails.logger.info("RawEmail #{job.arguments.first&.id}: inbound copy " \
                      'still being routed; left to Action Mailbox')
  end

  def perform(raw_email)
    return unless raw_email.read?

    inbound = raw_email.inbound_email or return
    raise StillRouting if inbound.pending? || inbound.processing?

    inbound.destroy! if inbound.delivered? || inbound.bounced?
  end
end
