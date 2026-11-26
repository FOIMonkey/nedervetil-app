# Copyright (c) 2007 UK Citizens Online Democracy. All rights reserved.
# Email: hello@mysociety.org; WWW: http://www.mysociety.org/

# Searches, inspects, edits, moves, deletes and reverts user reports on
# InfoRequest records in the admin interface.
class Admin::RequestsController < AdminController
  # A flat JSON body keeps the key it had before this controller moved here.
  wrap_parameters :admin_request, exclude: []

  include Admin::Searchable
  include Admin::Sortable

  before_action :set_info_request, :check_info_request, only: %i[
    show edit update destroy move prominence revert_report
  ]

  sortable default: :updated_at_desc, relevance: :indexed_search?,
           only: [:index]

  def index
    @query = params[:query]
    @query = nil if @query == ''

    info_requests = info_request_scope

    @info_requests = measure_search(
      sorted(
        info_requests.includes(:user, public_body: :translations)
      ).paginate(page: params[:page], per_page: 100)
    )
  end

  def show
  end

  def edit
  end

  def update
    old_title = @info_request.title
    old_prominence = @info_request.prominence
    old_prominence_reason = @info_request.prominence_reason
    old_described_state = @info_request.described_state
    old_awaiting_description = @info_request.awaiting_description
    old_allow_new_responses_from = @info_request.allow_new_responses_from
    old_handle_rejected_responses = @info_request.handle_rejected_responses
    old_tag_string = @info_request.tag_string

    if @info_request.update(info_request_params)
      @info_request.log_event(
        'edit',
        editor: admin_current_user,
        old_title: old_title,
        title: @info_request.title,
        old_prominence: old_prominence,
        prominence: @info_request.prominence,
        old_prominence_reason: old_prominence_reason,
        prominence_reason: @info_request.prominence_reason,
        old_described_state: old_described_state,
        described_state: params[:info_request][:described_state],
        old_awaiting_description: old_awaiting_description,
        awaiting_description: @info_request.awaiting_description,
        old_allow_new_responses_from: old_allow_new_responses_from,
        allow_new_responses_from: @info_request.allow_new_responses_from,
        old_handle_rejected_responses: old_handle_rejected_responses,
        handle_rejected_responses: @info_request.handle_rejected_responses,
        old_tag_string: old_tag_string,
        tag_string: @info_request.tag_string
      )
      if @info_request.described_state !=
         params[:info_request][:described_state]
        @info_request.set_described_state(
          params[:info_request][:described_state]
        )
      end
      # expire cached files
      @info_request.expire
      flash[:notice] = 'Request successfully updated.'
      redirect_to admin_request_url(@info_request)
    else
      render action: 'edit', status: :unprocessable_content
    end
  end

  def destroy
    user = @info_request.user
    url_title = @info_request.url_title

    @info_request.destroy

    flash[:notice] =
      "Request #{ url_title } has been completely destroyed. " \
      "Email of user who made request: #{ user.email }"
    redirect_to admin_requests_url
  end

  # change user or public body of a request magically
  def move
    editor = admin_current_user

    if params[:commit] == 'Move request to user' &&
       params[:user_url_name].present?
      lookup = params[:user_url_name].strip
      destination_user = User.find_by_url_name(lookup) ||
                         User.find_by('LOWER(email) = LOWER(?)', lookup)

      if @info_request.move_to_user(destination_user, editor: editor)
        flash[:notice] = 'Message has been moved to new user'
      else
        flash[:error] = "Couldn't find user '#{params[:user_url_name]}'"
      end

    elsif params[:commit] == 'Move request to authority' &&
          params[:public_body_url_name].present?
      lookup = params[:public_body_url_name].strip
      destination_body = PublicBody.find_by_url_name(lookup)

      if @info_request.move_to_public_body(destination_body, editor: editor)
        flash[:notice] = 'Request has been moved to new body'
      else
        flash[:error] =
          "Couldn't find public body '#{params[:public_body_url_name]}'"
      end

    else
      flash[:error] =
        'Please enter the user or authority to move the request to'
    end
    redirect_to admin_request_url(@info_request)
  end

  def prominence
    new_prominence = params[:prominence].to_s
    unless InfoRequest::Prominence::VALUES.include?(new_prominence)
      flash[:error] = 'Invalid visibility setting.'
      return redirect_to safe_return_path(admin_request_url(@info_request))
    end

    old_prominence = @info_request.prominence
    old_reason = @info_request.prominence_reason
    new_reason = if new_prominence == 'hidden'
                   params[:prominence_reason].to_s.strip
                 else
                   ''
                 end

    if @info_request.update(prominence: new_prominence,
                            prominence_reason: new_reason)
      @info_request.log_event(
        'edit',
        editor: admin_current_user,
        old_prominence: old_prominence,
        prominence: @info_request.prominence,
        old_prominence_reason: old_reason,
        prominence_reason: @info_request.prominence_reason
      )
      @info_request.expire
      flash[:notice] = if new_prominence == 'hidden'
                         'Request hidden from the requester.'
                       else
                         'Request restored to the requester.'
                       end
    else
      flash[:error] = @info_request.errors.full_messages.to_sentence
    end
    redirect_to safe_return_path(admin_request_url(@info_request))
  end

  def revert_report
    # A form without the report it showed (0) is refused as stale.
    @info_request.revert_report!(
      editor: admin_current_user,
      report_event_id: params[:report_event_id].to_i
    )
  rescue InfoRequest::RevertReportError => e
    flash[:error] = e.message
    redirect_to safe_return_path(admin_request_path(@info_request))
  else
    flash[:notice] = 'Request status reverted to ' \
                     "#{@info_request.described_state}."
    redirect_to safe_return_path(admin_request_path(@info_request))
  end

  private

  def info_request_scope
    return InfoRequest unless @query

    legacy_search? ? legacy_info_request_scope : indexed_info_request_scope
  end

  def legacy_info_request_scope
    InfoRequest.where(
      ["lower(title) like lower('%'||?||'%')", @query]
    )
  end

  def indexed_info_request_scope
    InfoRequest.search_scope(@query, admin_mode: true)
  end

  def info_request_params
    if params[:info_request]
      params.require(:info_request).permit(:title,
                                           :prominence,
                                           :prominence_reason,
                                           :described_state,
                                           :awaiting_description,
                                           :allow_new_responses_from,
                                           :handle_rejected_responses,
                                           :tag_string)
    else
      {}
    end
  end

  def set_info_request
    @info_request = InfoRequest.find(params[:id].to_i)
  end

  def check_info_request
    return if can? :admin, @info_request

    raise ActiveRecord::RecordNotFound
  end

  def safe_return_path(fallback)
    path = params[:return_to].to_s
    valid = %r{\A/admin(?:/[^\s\\]*)?(?:\?[^\s\\]*)?\z}.match?(path) &&
            !path.include?("\r") && !path.include?("\n")
    return path if valid

    fallback
  end
end
