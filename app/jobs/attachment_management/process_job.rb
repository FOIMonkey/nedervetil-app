module AttachmentManagement
  # Background worker running Processor on an AttachmentManagement::Revision.
  class ProcessJob < ApplicationJob
    queue_as :documents

    def perform(revision_id)
      revision = Revision.find_by(id: revision_id)
      return unless revision&.processing?

      Processor.new(revision).run
      CleanupJob.enqueue_if_due
    rescue StandardError => e
      fail_revision(revision,
                    PlainTextTranslation._('Processing failed: {{message}}',
                                           message: e.class))
      # ApplicationJob reports a job's last failed attempt, but the next
      # attempt at this revision finds it failed and stops without an error.
      report_failure(e) if revision
      raise
    end

    def fail_revision(revision, error)
      return unless revision

      revision.with_status_lock(%w[processing]) do
        revision.output.purge if revision.output.attached?
        revision.update!(status: 'failed', error: error)
      end
    end

    private

    def report_failure(error)
      return unless send_exception_notifications?

      ExceptionNotifier.notify_exception(
        error, data: { job: self.class.to_s, job_id: job_id }
      )
    end
  end
end
