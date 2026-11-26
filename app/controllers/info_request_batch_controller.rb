# Shows an InfoRequestBatch and its readable requests (or queued authorities)
# to its owner or an admin, redirecting owners into the inbox view.
class InfoRequestBatchController < ApplicationController
  before_action :set_in_pro_area, only: [:show]
  before_action :load_and_authorise_resource, only: [:show]
  before_action :redirect_own_batches_to_inbox, only: [:show]

  def show
    @per_page = 25
    @page = page_from_params
    if @info_request_batch.sent_at
      @info_requests = load_info_requests.
        preload(:user, :outgoing_messages, :deadline_adjustments,
                :deadline_closures, public_body: %i[translations tags]).
        paginate(page: @page, per_page: @per_page)
      @sending_events = sending_events(@info_requests)
    else
      @public_bodies = load_public_bodies.paginate(page: @page,
                                                   per_page: @per_page)
    end
  end

  private

  def load_and_authorise_resource
    @info_request_batch = InfoRequestBatch.find(params[:id])
    raise ActiveRecord::RecordNotFound if cannot?(:read, @info_request_batch)
  end

  def redirect_own_batches_to_inbox
    return if params[:pro] == "1"
    return unless current_user && @info_request_batch.user == current_user

    redirect_to show_alaveteli_pro_batch_request_url(@info_request_batch)
  end

  def load_info_requests
    readable = @info_request_batch.readable_info_requests(current_ability)
    @info_request_batch.info_requests.visible_to_requester.
      where(id: readable.select(:id))
  end

  # Batch-load sending events and attach loaded requests to avoid N+1 queries.
  def sending_events(requests)
    events = InfoRequestEvent.
      where(id: requests.map(&:last_event_forming_initial_request_id)).
      index_by(&:id)
    requests.to_h do |request|
      event = events[request.last_event_forming_initial_request_id] ||
              request.last_event_forming_initial_request
      event.association(:info_request).target = request
      [request.id, event]
    end
  end

  def load_public_bodies
    @info_request_batch.public_bodies
  end
end
