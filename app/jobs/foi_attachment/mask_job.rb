##
# Job to apply masks and censor rules to FoiAttachment objects. Masked file will
# be stored as FoiAttachment#file ActiveStorage association.
#
# Example:
#   FoiAttachment::MaskJob.perform(FoiAttachment.first)
#
class FoiAttachment::MaskJob < ApplicationJob
  queue_as :default
  unique :until_executed, on_conflict: :log

  # Release the until_executed lock before retry_on re-enqueues, or the retry
  # is dropped as a duplicate; unlock deletes one key (unlike unlock!'s scan).
  around_perform do |job, block|
    block.call
  rescue StandardError
    job.lock_strategy.unlock(resource: job.lock_key)
    raise
  end

  # Retries refused mail reads, then leaves masking to the next access without
  # alerting (the mail health check reports outages; see doc/FORK.md).
  retry_on MailHandler::ReadRefused,
           wait: :polynomially_longer, attempts: 5 do |job, error|
    Rails.logger.warn("FoiAttachment::MaskJob #{job.arguments.first&.id}: " \
                      "#{error.message}; left to the next read")
  end

  PAGE_RETRY_EVERY = 10.minutes

  # Direct runs (enqueued_at nil) re-raise ReadRefused to callers instead of
  # piling up retries; web pages debounce one background run via cache.
  def rescue_with_handler(error)
    return super unless error.is_a?(MailHandler::ReadRefused) &&
                        enqueued_at.nil?

    mask_later_for_pages if MailHandler::Reading.for_page?
    nil
  end

  # Enqueues one background mask per PAGE_RETRY_EVERY for slow emails that
  # exceed PAGE_SECONDS. Enqueue runs before the cache write so a failed
  # enqueue (or unreachable cache) still retries on the next page view.
  def mask_later_for_pages
    key = "foi_attachment/mask-for-pages/#{arguments.first.id}"
    return if Rails.cache.read(key)

    self.class.perform_later(*arguments)
    Rails.cache.write(key, true, expires_in: PAGE_RETRY_EVERY)
  rescue StandardError => e
    Rails.logger.error("FoiAttachment::MaskJob not queued for pages: " \
                       "#{e.class}: #{e.message}")
  end

  # DeserializationError discards before perform callbacks, which would strand
  # the uniqueness lock for a day (even on transient DB errors).
  after_discard do |job, error|
    next unless error.is_a?(ActiveJob::DeserializationError)

    ActiveJob::Uniqueness.lock_manager.delete_lock(job.queued_lock_key)
  end

  # Rebuilds ActiveJob::Uniqueness::LockKey from raw serialized arguments.
  def queued_lock_key
    config = ActiveJob::Uniqueness.config
    digest = config.digest_method.hexdigest(
      ActiveSupport::JSON.encode(serialize['arguments'])
    )
    [config.lock_prefix, self.class.name.underscore, digest].join(':')
  end

  attr_reader :attachment

  delegate :incoming_message, to: :attachment
  delegate :info_request, to: :incoming_message

  def perform(attachment)
    Current.without_memo do
      @attachment = attachment
      mask
    end
  end

  private

  def mask
    # Skip if masked after this job was enqueued (1s margin for second-precision
    # enqueued_at); still runs when invoked directly or re-masking old masks.
    queued = enqueued_at.is_a?(String) ? Time.iso8601(enqueued_at) : enqueued_at
    if queued && attachment.masked? && attachment.masked_at > queued + 1.second
      return
    end

    attachment.mask

    # Masking faulted (timeout or PDF error); requester still gets a copy
    # (Maskable#masking_outcome). Notify once on the first fault.
    if attachment.masking_failed? &&
       attachment.masking_failed_at_previously_changed?
      notify_masking_failure
    end
    return unless attachment.file.attached?

    # ensure the after_commit callback runs which uploads the blob, without this
    # the callback might not execute in time and the job exits resulting in the
    # lost of the masked attachment body.
    return if attachment.file_blob.service.exist?(attachment.file_blob.key)

    attachment.run_callbacks(:commit)
  end

  def notify_masking_failure
    return unless send_exception_notifications?

    ExceptionNotifier.notify_exception(
      masking_failure, data: { foi_attachment: attachment.id }
    )
  end

  def masking_failure
    error = attachment.masking_error
    if error.is_a?(AlaveteliTextMasker::PDFMaskingError)
      error.class.new("PDF masking failed (ID=#{attachment.id}): " \
                      "#{error.message}")
    else
      Regexp::TimeoutError.new("masking timed out (ID=#{attachment.id})")
    end
  end
end
