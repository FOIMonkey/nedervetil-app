# Copyright (c) 2007 UK Citizens Online Democracy. All rights reserved.
# Email: hello@mysociety.org; WWW: http://www.mysociety.org/

# Shows private InfoRequests, details, event links and zip downloads, and lets
# signed-out visitors draft a request before signing in.
class RequestController < ApplicationController
  read_only :requests, only: [:new]

  # Bound anonymous draft cache writes independently of cookies or edge limits.
  rate_limit to: 10, within: 10.minutes, only: :new,
             if: -> { request.post? && !current_user },
             name: 'anonymous-draft-ip'
  rate_limit to: 100, within: 1.hour, only: :new,
             if: -> { request.post? && !current_user },
             name: 'anonymous-draft-site', by: -> { 'site' }

  # Only these fields carry over sign-in to become an owned draft.
  DRAFT_FIELDS = {
    info_request: %i[title public_body_id],
    outgoing_message: %i[body]
  }.freeze

  # Full load preserves typed text on Back (see doc/FORK.md).
  turbo_drive false, only: :new

  before_action :set_info_request, only: [:show]
  before_action :redirect_accounts_to_inbox_form,
                only: [:select_authority, :new]
  before_action :set_no_crawl_headers, only: [:new, :details]
  # The page applies the request's censor rules hundreds of times.
  around_action :memoise_page, only: :show

  helper_method :state_transitions_empty?
  # The request zip's text file is a text render of request/show.
  helper PlainTextTranslation::View

  before_action :require_event_message_read, only: :show_request_event

  def select_authority
    # Check whether we force the user to sign in right at the start, or we allow
    # her to start filling the request anonymously
    if AlaveteliConfiguration.force_registration_on_new_request &&
       !authenticated?
      ask_to_login(
        web: _('To send your FOI request'),
        email: _("Then you'll be allowed to send FOI requests."),
        email_subject: _('Confirm your email address')
      )
      return
    end
    unless params[:query].nil?
      query = params[:query]
      @request_results = typeahead_search(query, model: PublicBody)
    end
    medium_cache
  end

  def show
    medium_cache
    AlaveteliLocalization.with_locale(locale) do
      # Test for whole request being hidden
      return render_hidden if cannot?(:read, @info_request)

      remember_last_request(@info_request)

      # assign variables from request parameters
      @collapse_quotes = !params[:unfold]

      @update_status = params[:update_status] == "1"

      assign_variables_for_show_template(@info_request)

      # Only owners (and people who own everything) can update status
      if @update_status && !@is_owning_user && !authenticated?(
        as: @info_request.user
      )
        ask_to_login(
          as: @info_request.user,
          web: _('To update the status of this FOI request'),
          email: _('Then you can update the status of your request to ' \
                   '{{authority_name}}.',
                   authority_name: @info_request.public_body.name),
          email_subject: _('Update the status of your request to ' \
                           '{{authority_name}}',
                           authority_name: @info_request.public_body.name)
        )
        return
      end

      # What state transitions can the request go into
      assign_state_transition_variables

      # Sidebar stuff
      @sidebar = true

      render template: 'request/show'
    end
  end

  # Extra info about a request, such as event history
  def details
    long_cache
    @info_request = InfoRequest.find_by_url_title!(params[:url_title])
    render_hidden if cannot?(:read, @info_request)
  end

  # Page new form posts to
  def new
    # All new requests are of normal_sort
    unless params[:outgoing_message].nil?
      params[:outgoing_message][:what_doing] = 'normal_sort'
    end

    # Signed-in accounts are redirected to the inbox form; signed-out visitors
    # compose here and convert the draft via PendingRequestDraft on sign-in.

    # First time we get to the page, just display it
    if !request.post? || params[:submitted_new_request].nil? || params[:reedit]
      return render_new_compose
    end

    # CREATE ACTION

    # Check we have :public_body_id - spammers seem to be using :public_body
    # erroneously instead
    if params[:info_request][:public_body_id].blank?
      redirect_to frontpage_path and return
    end

    # Create both FOI request and the first request message
    @info_request = InfoRequest.build_from_attributes(info_request_params,
                                                      outgoing_message_params)
    @outgoing_message = @info_request.outgoing_messages.first

    # Maybe we lost the address while they're writing it
    unless @info_request.public_body.is_requestable?
      reason = @info_request.public_body.not_requestable_reason
      render action: "new_#{reason}", status: :unprocessable_content
      return
    end

    # See if values were valid or not
    unless @info_request.valid?
      # We don't want the error "Outgoing messages is invalid", as in this
      # case the list of errors will also contain a more specific error
      # describing the reason it is invalid.
      @info_request.errors.delete(:outgoing_messages)

      render action: 'new', status: :unprocessable_content
      return
    end

    # Show preview page, if it is a preview
    return render_new_preview if params[:preview].to_i == 1

    ask_to_login(
      keep: DRAFT_FIELDS,
      web: _('To send your FOI request').to_str,
      email: _('Then you can check your FOI request to {{public_body_name}} ' \
               'and send it.',
               public_body_name: @info_request.public_body.name),
      email_subject: _('Confirm your FOI request to {{public_body_name}}',
                       public_body_name: @info_request.public_body.name)
    )
  end

  # Used for links from polymorphic URLs e.g. in Atom feeds - just redirect to
  # proper URL for the message the event refers to
  def show_request_event
    @info_request_event = InfoRequestEvent.find(params[:info_request_event_id])

    if @info_request_event.is_incoming_message?
      redirect_to incoming_message_url(@info_request_event.incoming_message),
                  status: :moved_permanently
    elsif @info_request_event.is_outgoing_message?
      redirect_to outgoing_message_url(@info_request_event.outgoing_message),
                  status: :moved_permanently
    else
      # TODO: maybe there are better URLs for some events than this
      redirect_to request_url(@info_request_event.info_request),
                  status: :moved_permanently
    end
  end

  def download_entire_request
    AlaveteliLocalization.with_locale(locale) do
      @info_request = InfoRequest.find_by_url_title!(params[:url_title])
      if !authenticated?
        ask_to_login(
          web: _('To download the zip file'),
          email: _('Then you can download a zip file of ' \
                   '{{info_request_title}}.',
                   info_request_title: @info_request.title),
          email_subject: _('Log in to download a zip file of ' \
                           '{{info_request_title}}',
                           info_request_title: @info_request.title)
        )
      else
        return render_hidden if cannot?(:read, @info_request)

        if defined?(RegulatorPack)
          RegulatorPack.enqueue_for(@info_request, @user)
          flash[:notice] = _(
            'We are preparing your download. We will email you a link once it ' \
            'is ready; the link expires after 48 hours.'
          )
        end
        redirect_to show_request_path(@info_request.url_title)
      end
    end
  end

  private

  # Prevent event redirects from confirming the existence of a hidden message.
  def require_event_message_read
    event = InfoRequestEvent.find(params[:info_request_event_id])
    message = if event.is_incoming_message?
                event.incoming_message
              elsif event.is_outgoing_message?
                event.outgoing_message
              else
                return
              end
    raise ActiveRecord::RecordNotFound if cannot?(:read, message)
  end

  def info_request_params
    params.require(:info_request).permit(:title, :public_body_id, :tag_string)
  end

  def outgoing_message_params
    params.require(:outgoing_message).permit(:body, :what_doing)
  end

  def assign_variables_for_show_template(info_request)
    @info_request = info_request
    @status = info_request.calculate_status
    @old_unclassified =
      info_request.is_old_unclassified? && authenticated?
    # Whether to offer the forms for describing the request's state.
    @is_owning_user = can?(:update_request_state, info_request)
    @last_info_request_event_id = info_request.last_event_id_needing_description
    @new_responses_count =
      info_request.
      events_needing_description.
      count { |event| event.event_type == 'response' }

    # For send followup link at bottom
    @last_response = info_request.last_public_response

    @show_top_describe_state_form =
      (@update_status || @info_request.awaiting_description) &&
      !@render_to_file

    @show_bottom_describe_state_form =
      @info_request.awaiting_description && !@render_to_file

    @show_owner_update_status_action = !@old_unclassified && !@render_to_file

    @show_other_user_update_status_action =
      @old_unclassified.present? && !@render_to_file

    @show_action_menu = !@render_to_file
  end

  def assign_state_transition_variables
    @state_transitions = @info_request.state.transitions(
      is_owning_user: @is_owning_user,
      user_asked_to_update_status: @update_status
    )

    # If there are no available transitions, we shouldn't show any options
    # to update the status
    return unless state_transitions_empty?(@state_transitions)

    @show_top_describe_state_form = false
    @show_bottom_describe_state_form = false
    @show_owner_update_status_action = false
    @show_other_user_update_status_action = false
  end

  def state_transitions_empty?(transitions)
    return true if transitions.nil?

    transitions[:pending].empty? && \
      transitions[:complete].empty? && \
      transitions[:other].empty?
  end

  def render_new_compose
    params[:info_request] = {} unless params[:info_request]

    # Reconstruct the params
    # first the public body (by URL name or id)
    params[:info_request][:public_body_id] ||=
      if params[:url_name]
        if /^[0-9]+$/.match?(params[:url_name])
          PublicBody.find(params[:url_name]).id
        else
          public_body =
            PublicBody.find_by_url_name_with_historic(params[:url_name])
          if public_body.nil? # TODO: proper 404
            raise ActiveRecord::RecordNotFound, "None found"
          end

          public_body.id
        end
      elsif params[:public_body_id]
        params[:public_body_id]
      end

    unless params[:info_request][:public_body_id]
      # compulsory to have a body by here, or go to front page which is start
      # of process
      redirect_to frontpage_url
      return
    end

    # ... next any tags or other things
    params[:info_request][:title] = params[:title] if params[:title]
    params[:info_request][:tag_string] = params[:tags] if params[:tags]

    @info_request = InfoRequest.new(info_request_params)

    params[:info_request_id] = @info_request.id

    # Manually permit params because strong params was too difficult given the
    # non-standard arrangement.
    message_params =
      if params[:outgoing_message]
        { outgoing_message: params[:outgoing_message] }
      else
        { outgoing_message: {} }
      end

    message_params[:outgoing_message][:body] ||= params[:body] if params[:body]
    if params[:default_letter]
      message_params[:outgoing_message][:default_letter] ||=
        params[:default_letter]
    end

    message_params = ActionController::Parameters.new(message_params)
    permitted = message_params.
      permit(outgoing_message: [:body, :default_letter, :what_doing])

    @outgoing_message = OutgoingMessage.new(info_request: @info_request)

    if permitted[:outgoing_message][:body]
      @outgoing_message.body = permitted[:outgoing_message][:body]
    end
    if permitted[:outgoing_message][:default_letter]
      @outgoing_message.default_letter =
        permitted[:outgoing_message][:default_letter]
    end
    if permitted[:outgoing_message][:what_doing]
      @outgoing_message.what_doing = permitted[:outgoing_message][:what_doing]
    end

    if @info_request.public_body.is_requestable?
      render action: 'new'
    elsif @info_request.public_body.not_requestable_reason == 'bad_contact'
      render action: 'new_bad_contact'
    else
      # if not requestable because defunct or not_apply, redirect to main page
      # (which doesn't link to the /new/ URL)
      redirect_to public_body_url(@info_request.public_body)
    end
    nil
  end

  def render_new_preview
    if @outgoing_message.contains_email? || @outgoing_message.contains_postcode?
      flash.now[:error] = {
        partial: "preview_errors",
        locals: {
          contains_email: @outgoing_message.contains_email?,
          contains_postcode: @outgoing_message.contains_postcode?,
          help_link: help_privacy_path(anchor: "email_address"),
          user: @user
        }
      }
    end
    render action: 'preview'
  end

  # Signed-in accounts compose in the inbox form (which runs NewRequestChecks).
  def redirect_accounts_to_inbox_form
    return unless request_user

    if request.post? && params[:info_request] && params[:outgoing_message]
      raise PermissionDenied unless can?(:create, InfoRequest)

      pending = PendingRequestDraft.capture(session,
        title: params.dig(:info_request, :title),
        body: params.dig(:outgoing_message, :body),
        public_body_id: params.dig(:info_request, :public_body_id))
      pending&.bind_to(current_user)
      draft = PendingRequestDraft.claim(session, current_user)
      if draft
        return redirect_to(
          new_alaveteli_pro_info_request_path(draft_id: draft.id)
        )
      end
    end
    if params[:url_name]
      redirect_to(
        new_alaveteli_pro_info_request_url(public_body: params[:url_name])
      )
    else
      redirect_to new_alaveteli_pro_info_request_url
    end
  end

  def request_user
    current_user
  end

  def set_info_request
    AlaveteliLocalization.with_locale(locale) do
      @info_request ||= InfoRequest.find_by_url_title!(params[:url_title])
    end
  end

  def locale
    @locale ||= AlaveteliLocalization.locale
  end
end
