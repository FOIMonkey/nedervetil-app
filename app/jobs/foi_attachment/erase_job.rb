##
# Job to erase a FoiAttachment.
#
# Example:
#   FoiAttachment::EraseJob.perform_later(
#     FoiAttachment.first, editor: User.first, reason: 'GDPR request'
#   )
#
class FoiAttachment::EraseJob < ApplicationJob
  queue_as :default
  unique :until_and_while_executing, on_conflict: :log

  # Erasing requires masking siblings from raw mail first; retries ReadRefused
  # for ~11 hours, then logs an error and alerts since erasure did not occur.
  READ_ATTEMPTS = IncomingMessage::StoreTextJob::READ_ATTEMPTS

  retry_on MailHandler::ReadRefused,
           wait: :polynomially_longer, attempts: READ_ATTEMPTS do |job, error|
    Rails.logger.error(
      "FoiAttachment::EraseJob #{job.arguments.first&.id}: not erased " \
      "after #{READ_ATTEMPTS} tries (#{error.message})"
    )
    next unless job.send_exception_notifications?

    ExceptionNotifier.notify_exception(
      error, data: { job: job.class.to_s, job_id: job.job_id }
    )
  end

  def perform(attachment, editor:, reason:)
    attachment.erase(editor: editor, reason: reason)
  end
end
