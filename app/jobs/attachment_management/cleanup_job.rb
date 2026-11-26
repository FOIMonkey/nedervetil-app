module AttachmentManagement
  # Normal use enqueues it at most once a day, so working copies expire
  # without extra setup; cron can run it as well:
  #   bin/rails runner 'AttachmentManagement::CleanupJob.perform_now'
  class CleanupJob < ApplicationJob
    queue_as :low

    def self.stamp
      Pathname(AttachmentManagement.workspace).join('.last-cleanup')
    end

    def self.enqueue_if_due(now: Time.current)
      return if stamp.exist? && stamp.mtime > now - 1.day

      FileUtils.mkdir_p(AttachmentManagement.workspace)
      FileUtils.touch(stamp)
      perform_later
    end

    def perform
      result = Retention.new.run
      FileUtils.mkdir_p(AttachmentManagement.workspace)
      FileUtils.touch(self.class.stamp)
      Rails.logger.info("AttachmentManagement::Retention #{result.to_h}")
      result
    end
  end
end
