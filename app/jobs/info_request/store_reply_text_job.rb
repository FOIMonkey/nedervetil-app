# Re-caches main body text for replies cleared by InfoRequest::ExpireJob in
# bounded batches; unreached replies populate on first read (doc/FORK.md).
class InfoRequest::StoreReplyTextJob < ApplicationJob
  queue_as :low

  # Per-run cap and time budget before re-enqueueing, so large sweeps yield
  # the queue to other jobs even when conversions are slow.
  BATCH = 100
  TIME = 20.seconds

  # Transient DB errors re-raise to retry the batch instead of skipping a reply.
  DATABASE_FAILURES = [
    ActiveRecord::ConnectionNotEstablished, ActiveRecord::QueryAborted,
    ActiveRecord::TransactionRollbackError, ActiveRecord::LockWaitTimeout
  ].freeze

  def perform(object, after: 0)
    ids = replies(object).where(id: (after + 1)..).pluck(:id)
    last = store_until_time(ids)
    return if last == ids.last && ids.size < BATCH

    self.class.perform_later(object, after: last)
  end

  private

  def replies(object)
    requests = object == InfoRequest ? InfoRequest.all : object.info_requests
    IncomingMessage.where(info_request_id: requests.reorder(nil).select(:id),
                          cached_main_body_text_folded: nil).
      order(:id).limit(BATCH)
  end

  # Always processes at least one id before checking TIME so cursor advances.
  def store_until_time(ids)
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    ids.find do |id|
      store(id)
      Process.clock_gettime(Process::CLOCK_MONOTONIC) - started >= TIME
    end || ids.last
  end

  # Loads one reply at a time to bound parsed-mail memory; per-reply errors
  # are logged and skipped so one bad reply does not stall the sweep.
  def store(id)
    IncomingMessage.find_by(id: id)&.store_main_body_text!
  rescue *DATABASE_FAILURES
    raise
  rescue StandardError => e
    Rails.logger.warn(
      "IncomingMessage #{id}: text not stored after expiry (#{e.class})"
    )
  end
end
