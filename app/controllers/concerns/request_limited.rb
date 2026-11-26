# The responses for the request limits (RequestLimits) in the controllers
# that create requests, follow-ups and batches.
module RequestLimited
  private

  def render_request_limit(refusal, message: nil, draft: false)
    @refusal = refusal
    @limited_message = message
    @limited_draft = draft
    render 'request_limits/limited', status: :too_many_requests
  end

  def require_batch_permission
    return if can?(:create, InfoRequestBatch)

    raise ActiveRecord::RecordNotFound
  end
end
