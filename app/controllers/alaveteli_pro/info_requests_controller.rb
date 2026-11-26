# Copyright (c) 2008 UK Citizens Online Democracy. All rights reserved.
# Email: hello@mysociety.org; WWW: http://www.mysociety.org/

# Lists a signed-in user's inbox requests and handles composing, previewing and
# sending single FOI requests through the inbox request flow.
class AlaveteliPro::InfoRequestsController < AlaveteliPro::BaseController
  include RequestJourney::ProRequestSteps
  include NewRequestChecks

  # Keep :index open in maintenance so read_only's redirect does not loop.
  read_only :requests, only: %i[new preview create]

  # Full load preserves typed text on Back (see doc/FORK.md).
  turbo_drive false, only: %i[new preview create]

  before_action :set_draft
  before_action :set_public_body, only: [:new]
  before_action :load_data_from_draft, only: [:preview, :create]
  before_action :check_public_body_is_requestable, only: [:preview, :create]
  before_action :check_banned, only: [:new, :preview, :create]
  # Share AI reading decisions across sidebar counts, filter and groups.
  around_action :memoise_page, only: :index

  def index
    @request_filter = AlaveteliPro::RequestFilter.new
    if params[:alaveteli_pro_request_filter]
      @request_filter.update(request_filter_params)
    end
    request_summaries = @request_filter.results(current_user)
    @page = params[:page] || 1
    @per_page = 10
    @request_summaries = request_summaries.paginate page: @page,
                                                    per_page: @per_page
    return unless defined?(IncomingAttention::Effective) &&
                  IncomingAttention::Effective.active?

    filter = params.dig(:alaveteli_pro_request_filter, :filter).presence
    return unless filter && filter != 'draft'

    @attention_data = IncomingAttention::Effective.page_data(
      @request_summaries.to_a, user: current_user
    )
  end

  def new
    @user = current_user
    if @draft_info_request
      load_data_from_draft
    else
      create_initial_objects
    end
    check_public_body_is_requestable
    return if performed?

    start_journey
  end

  def preview
    set_journey_context
    @step = :review
    if all_models_valid?
      render "preview"
    else
      show_errors
    end
  end

  def create
    unless RequestJourney::Review.valid?(@draft_info_request,
                                         params[:review_token])
      return redirect_to(
        preview_new_alaveteli_pro_info_request_path(
          draft_id: @draft_info_request.id
        ),
        notice: _('Check the finished letter before sending.')
      )
    end

    if all_models_valid?
      refusal = new_request_refusal(@info_request)
      return refuse_to_send(refusal) if refusal

      @info_request.save! # Saves @outgoing_message too
      sent = send_initial_message(@outgoing_message)
      destroy_draft
      if sent
        flash[:request_sent] = true
      else
        flash[:error] = _('An error occurred while sending your request to ' \
                          '{{authority_name}} but has been saved and ' \
                          'flagged for administrator attention.',
                          authority_name: @info_request.public_body.name)
      end
      redirect_to show_request_path(url_title: @info_request.url_title)
    else
      show_errors
    end
  end

  private

  def check_banned
    return unless authenticated? && cannot?(:create, InfoRequest)

    @details = authenticated_user.can_fail_html
    render(template: 'user/banned', status: failed_submit_status) && return
  end

  def refuse_to_send(message)
    flash.now[:error] = message
    @step = :review
    set_journey_context
    render 'preview', status: :unprocessable_content
  end

  def show_errors
    @step = :write
    set_journey_context
    # There'll be a duplicate error if the outgoing_message is invalid, so
    # delete it
    @info_request.errors.delete(:outgoing_messages)
    render "new", status: :unprocessable_content
  end

  def all_models_valid?
    @info_request.valid? && @outgoing_message.valid? && !repeat_of_own_request?
  end

  # Scoped to current_user to avoid leaking other users' private requests;
  # includes failed sends so admins don't later resend a duplicate.
  def repeat_of_own_request?
    existing = InfoRequest.find_existing(
      @info_request.title, @info_request.public_body_id, @outgoing_message.body,
      within: current_user.info_requests
    )
    return false unless existing

    @info_request.errors.add(
      :base,
      _('You already made the same request on {{date}}. Change it to send ' \
        'a new but similar request.',
        date: helpers.simple_date(existing.created_at, format: :text))
    )
    true
  end

  def set_draft
    save_letter if action_name == 'create'
    return if performed?
    return unless params[:draft_id]

    @draft_info_request =
      current_user.draft_info_requests.find(params[:draft_id])
  end

  def set_public_body
    return unless params[:public_body]

    @public_body = PublicBody.find_by_url_name(params[:public_body])
  end

  def load_data_from_draft
    unless @draft_info_request
      return redirect_to new_alaveteli_pro_info_request_path
    end

    @info_request = InfoRequest.from_draft(@draft_info_request)
    @outgoing_message = @info_request.outgoing_messages.first
  end

  def create_initial_objects
    @draft_info_request = DraftInfoRequest.new(public_body: @public_body)
    @info_request = InfoRequest.new(public_body: @public_body)
    @outgoing_message = OutgoingMessage.new(info_request: @info_request)
    @outgoing_message.add_signature(current_user.name)
  end

  def destroy_draft
    return unless params[:draft_id]

    current_user.draft_info_requests.destroy(params[:draft_id])
  end

  def send_initial_message(outgoing_message)
    mail_message = OutgoingMailer.initial_request(
      outgoing_message.info_request,
      outgoing_message
    ).deliver_now if outgoing_message.sendable?

  rescue *OutgoingMessage.expected_send_errors => e
    outgoing_message.record_email_failure(
      e.message
    )
    false
  else
    outgoing_message.record_email_delivery(
      mail_message.to_addrs.join(', '),
      mail_message.message_id
    )
    true
  end

  def request_filter_params
    params.
      require(:alaveteli_pro_request_filter).
        permit(:filter, :order, :search)
  end

  def check_public_body_is_requestable
    return if @info_request.public_body.nil? ||
              @info_request.public_body.is_requestable?

    reason = @info_request.public_body.not_requestable_reason
    view = "request/new_#{reason}"
    render view, status: failed_submit_status
  end
end
