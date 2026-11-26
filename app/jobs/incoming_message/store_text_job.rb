# Parses a reply's raw email and stores its main body text on arrival, then
# queues text readers (AI reading and document suggestions) so only one job
# builds the text. See doc/FORK.md for recovery paths.
class IncomingMessage::StoreTextJob < ApplicationJob
  queue_as :default

  # Transient conversion failures retry briefly, then fall back to first read
  # without exception alerts (unconvertible mail would alert every time).
  retry_on IncomingMessage::MainBody::NotStored,
           wait: :polynomially_longer, attempts: 3 do |_job, error|
    Rails.logger.warn("#{error.message}; left to the first read")
  end

  # Retries refused mail-cell reads for ~11 hours (covering deploys/outages),
  # then leaves the reply unparsed for first read with one exception alert.
  READ_ATTEMPTS = 12

  retry_on MailHandler::ReadRefused,
           wait: :polynomially_longer, attempts: READ_ATTEMPTS do |job, error|
    Rails.logger.warn("#{error.message}; left to the first read")
    next unless job.send_exception_notifications?

    ExceptionNotifier.notify_exception(
      error, data: { job: job.class.to_s, job_id: job.job_id }
    )
  end

  discard_on RawEmail::Erasable::ErasedError

  after_perform :queue_text_readers
  after_discard { |job, _error| job.queue_text_readers }

  # Parse first on its own so MailHandler::ReadRefused triggers retry_on;
  # storing text directly would fall back to the fallback notice instead.
  def perform(incoming_message)
    incoming_message.parse_raw_email
    incoming_message.mask_attachments!
    incoming_message.store_main_body_text!
  end

  def queue_text_readers
    message = arguments.first
    message.queue_text_readers if message.is_a?(IncomingMessage)
  end
end
