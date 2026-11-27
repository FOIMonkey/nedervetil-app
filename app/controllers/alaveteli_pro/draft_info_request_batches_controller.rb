# The inbox's batch drafts: the letter and the authorities a batch request
# is written for, saved before it is sent.
class AlaveteliPro::DraftInfoRequestBatchesController < AlaveteliPro::BaseController
  include AlaveteliPro::BatchRequest
  include RequestLimited

  read_only :requests, only: %i[create update update_bodies]

  before_action :require_batch_permission

  def create
    @draft = current_user.draft_info_request_batches.create(draft_params)
    respond_or_redirect(@draft)
  end

  # Skip validation so invalid edits persist and preview shows current errors
  # rather than stale saved text.
  def update
    @draft = current_user.draft_info_request_batches.find(params[:id])
    @draft.transaction do
      @draft.assign_attributes(draft_params_multiple_bodies)
      @draft.save!(validate: false)
    end
    if params[:preview]
      redirect_to preview_new_alaveteli_pro_info_request_batch_path(
        draft_id: @draft.id
      )
    else
      redirect_to(
        new_alaveteli_pro_info_request_batch_path(draft_id: @draft.id),
        notice: _("Your draft has been saved!")
      )
    end
  end

  def update_bodies
    @draft = current_user.draft_info_request_batches.
      find_by(id: update_bodies_params[:draft_id])
    case update_bodies_params[:action]
    when 'add-all' then add_all_draft_bodies
    when 'add' then add_draft_body
    when 'remove' then remove_draft_body
    end
    respond_or_redirect(@draft)
  end

  private

  def add_all_draft_bodies
    @draft ||= current_user.draft_info_request_batches.create
    requestable = PublicBody.visible.
      without_tag(PublicBody.batch_excluded_tags).
      with_tag(category_tag).select(&:is_requestable?)
    @draft.public_bodies << (requestable - @draft.public_bodies)
  end

  def add_draft_body
    public_body = PublicBody.visible.
      without_tag(PublicBody.batch_excluded_tags).
      find(update_bodies_params[:public_body_id])
    raise ActiveRecord::RecordNotFound unless public_body.is_requestable?

    @draft ||= current_user.draft_info_request_batches.create
    return if @draft.public_bodies.include?(public_body)

    @draft.public_bodies << public_body
  end

  def remove_draft_body
    public_body = PublicBody.find(update_bodies_params[:public_body_id])
    raise ActiveRecord::RecordNotFound unless @draft

    @draft.public_bodies.delete(public_body)
    @draft.destroy! if @draft.public_bodies.empty?
  end

  def respond_or_redirect(_draft)
    @query = params[:authority_query]
    @page = params[:page]
    if request.xhr?
      respond_with_partial(@draft, @query, @page)
    else
      redirect_after_create_or_update_bodies(@draft, @query, @page)
    end
  end

  def redirect_after_create_or_update_bodies(draft, query, page)
    redirect_params = { mode: mode,
                        category_tag: category_tag }

    if query
      redirect_params[:authority_query] = query
      redirect_params[:page] = page
    end

    if draft.persisted?
      redirect_params[:draft_id] = draft.id
      flash[:notice] = _('Your Batch Request has been saved!')
    end

    path =
      alaveteli_pro_batch_request_authority_searches_path(redirect_params)

    redirect_to path
  end

  def respond_with_partial(draft, query, page)
    render partial: 'summary',
           layout: false,
           locals: { draft: draft,
                     query: query,
                     page: page,
                     mode: mode,
                     category_tag: category_tag }
  end

  # #create and #update accept an array of public_body_ids, whereas
  # #update_bodies only take a single body to add or remove, hence the two
  # different params.
  def draft_params
    permitted = params.require(:alaveteli_pro_draft_info_request_batch).
                permit(:title, :body, :public_body_ids)
    if permitted.key?(:public_body_ids)
      permitted[:public_body_ids] =
        allowed_batch_body_ids([permitted[:public_body_ids]]).first
    end
    permitted
  end

  def draft_params_multiple_bodies
    permitted = params.require(:alaveteli_pro_draft_info_request_batch).
                permit(:title, :body, public_body_ids: [])
    if permitted.key?(:public_body_ids)
      permitted[:public_body_ids] =
        allowed_batch_body_ids(permitted[:public_body_ids])
    end
    permitted
  end

  def allowed_batch_body_ids(ids)
    cap = [RequestLimits.batch_authority_limit, 500].max
    candidates = Array(ids).reject(&:blank?).map(&:to_i).uniq.first(cap)
    return [] if candidates.empty?

    PublicBody.visible.is_requestable.
      without_tag(PublicBody.batch_excluded_tags).
      where(id: candidates).pluck(:id)
  end

  def update_bodies_params
    params.require(:alaveteli_pro_draft_info_request_batch).
      permit(:draft_id, :public_body_id, :action)
  end
end
