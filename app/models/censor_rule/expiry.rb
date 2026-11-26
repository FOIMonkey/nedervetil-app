# Handle updating of request content in response to CensorRule modifications
module CensorRule::Expiry
  extend ActiveSupport::Concern

  included do
    after_commit :expire_requests, if: :reaches_requester?
  end

  def expire_requests
    if global?
      InfoRequest::ExpireJob.perform_later(InfoRequest, :all)
    elsif censorable
      censorable.expire_requests
    end
  end
end
