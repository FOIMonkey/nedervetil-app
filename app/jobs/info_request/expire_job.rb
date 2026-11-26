##
# Job to expire InfoRequest objects. Can expire single requests, all requests or
# a collection of requests through an model associations.
#
# Examples:
#   InfoRequest::ExpireJob.perform(InfoRequest.first)
#   InfoRequest::ExpireJob.perform(InfoRequest, :all)
#   InfoRequest::ExpireJob.perform(PublicBody.first, :info_requests)
#
class InfoRequest::ExpireJob < ApplicationJob
  queue_as :low

  def perform(object, method = nil)
    expire(object, method)
    store_reply_text_later(object)
  end

  private

  def expire(object, method)
    return object.expire if object.is_a?(InfoRequest)

    if object == InfoRequest && method == :all
      enumerator = InfoRequest.all
    else
      association = object.association(method)
      enumerator = association.reader if association.klass == InfoRequest
    end

    enumerator.find_each(&:expire)
  end

  # Re-cache cleared reply text asynchronously after all expiries so it does
  # not delay expiry or checks; enqueue failures fall back to first read.
  def store_reply_text_later(object)
    InfoRequest::StoreReplyTextJob.perform_later(object)
  rescue StandardError => e
    Rails.logger.warn(
      "InfoRequest::ExpireJob: reply text not queued for storing (#{e.class})"
    )
  end
end
