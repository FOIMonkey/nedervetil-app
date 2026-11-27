# Lets a request's owner compose, preview and send a follow-up or internal
# review message on an InfoRequest, enforcing follow-up eligibility and limits.
class FollowupsController < ApplicationController
  include RequestLimited

  read_only :followups

  # Full load preserves typed text on Back (see doc/FORK.md).
  turbo_drive false, only: %i[new create preview]

  before_action :set_info_request,
                :set_incoming_message,
                :set_last_request_data,
                :check_incoming_message_can_be_followed_up,
                :check_request_matches_incoming_message,
                :authenticate,
                :check_user_can_followup,
                :set_params,
                :set_internal_review,
                :set_outgoing_message,
                :set_refusal_advice

  before_action :check_reedit, only: [:preview, :create]

  before_action :check_responses_allowed, only: [:create]

  def new
  end

  def create
    if @internal_review && Deadlines::FollowupLetter.scottish?(@info_request) &&
       (problem = Deadlines::FollowupLetter.
          scottish_problem(params[:review_reason], params[:review_more]))
      @outgoing_message.errors.add(:base, problem)
      return render(action: 'new', status: :unprocessable_content)
    end

    @outgoing_message.info_request = @info_request
    if @info_request.find_existing_outgoing_message(
      params.dig(:outgoing_message, :body)
    )
      flash.clear # otherwise the message sent notice may be redisplayed
      flash.now[:error] = _('You previously submitted that exact follow up ' \
                            'message for this request.')
    elsif @outgoing_message.valid?
      send_followup
      redirect_to request_url(@info_request) and return
    end
    render action: 'new', status: :unprocessable_content
  rescue RequestLimits::Exceeded => e
    render_request_limit(e.refusal, message: @outgoing_message&.body)
  end

  def preview
    @outgoing_message.info_request = @info_request
    @internal_review = true if @outgoing_message.what_doing == 'internal_review'
    return if @outgoing_message.valid?

    render action: 'new', status: :unprocessable_content
  end

  private

  def check_incoming_message_can_be_followed_up
    return if @info_request.is_followupable?(@incoming_message)

    @reason = @info_request.followup_bad_reason
    render action: 'followup_bad', status: failed_submit_status
  end

  def set_internal_review
    @internal_review = false
    @internal_review = true if params[:internal_review]
  end

  def check_reedit
    return unless params[:reedit]

    render action: 'new'
  end

  def check_request_matches_incoming_message
    if @incoming_message && (@info_request != @incoming_message.info_request)
      raise ActiveRecord::RecordNotFound,
            "Incoming message #{@incoming_message.id} does not belong " \
            "to request #{@info_request.id}"
    end
  end

  def check_responses_allowed
    return unless @info_request.allow_new_responses_from == "nobody"

    flash.now[:error] = { partial: "followup_not_sent",
                          locals: {
                            help_contact_path: help_contact_path
                          } }
    render action: 'new', status: :unprocessable_content
  end

  def authenticate
    # We want to make sure they're the right user first, before they start
    # writing a message and wasting their time if they are not the requester.
    authenticated?(as: @info_request.user) || ask_to_login(
      as: @info_request.user,
      **get_login_params(@incoming_message, @info_request)
    )
  end

  def check_user_can_followup
    return unless authenticated?
    return if can?(:follow_up, @info_request)

    @details = authenticated_user.can_fail_html
    render template: 'user/banned', status: failed_submit_status
  end

  def get_login_params(is_incoming, info_request)
    if is_incoming
      { web: _("To send a follow up message to {{authority_name}}",
                  authority_name: info_request.public_body.name),
        email: _("Then you can write follow up message to {{authority_name}}.",
                    authority_name: info_request.public_body.name),
        email_subject:
          _("Write your FOI follow up message to {{authority_name}}",
            authority_name: info_request.public_body.name) }
    else
      { web: _("To reply to {{authority_name}}.",
                  authority_name: info_request.public_body.name),
        email: _("Then you can write your reply to {{authority_name}}.",
                    authority_name: info_request.public_body.name),
        email_subject: _("Write a reply to {{authority_name}}",
                            authority_name: info_request.public_body.name) }
    end
  end

  def outgoing_message_params
    put_letter_in_body
    params_outgoing_message = params_to_unsafe_hash(params[:outgoing_message])

    params_outgoing_message.merge!(
      {
        status: 'ready',
        message_type: 'followup',
        incoming_message_followup_id: @incoming_message.try(:id),
        info_request_id: @info_request.id
      }
    )
    params_outgoing_message[:what_doing] = 'internal_review' if @internal_review

    parameters = ActionController::Parameters.new(params_outgoing_message)
    parameters.permit(:body,
                      :status,
                      :message_type,
                      :incoming_message_followup_id,
                      :info_request_id,
                      :what_doing)
  end

  def send_followup
    # OutgoingMailer.followup() depends on DB id of the
    # outgoing message, save just before sending.
    @outgoing_message.save!

    begin
      mail_message = OutgoingMailer.followup(
        @outgoing_message.info_request,
        @outgoing_message,
        @outgoing_message.incoming_message_followup
      ).deliver_now if @outgoing_message.sendable?

    rescue *OutgoingMessage.expected_send_errors => e
      authority_name = @outgoing_message.info_request.public_body.name
      @outgoing_message.record_email_failure(e.message)
      if @outgoing_message.what_doing == 'internal_review'
        flash[:error] = _("Your internal review request has been saved but " \
                          "not yet sent to {{authority_name}} due to an error.",
                          authority_name: authority_name)
      else
        flash[:error] = _("Your follow up message has been saved but not yet " \
                          "sent to {{authority_name}} due to an error.",
                          authority_name: authority_name)
      end
    else
      @outgoing_message.record_email_delivery(
        mail_message.to_addrs.join(', '),
        mail_message.message_id
      )

      if @outgoing_message.what_doing == 'internal_review'
        flash[:notice] = _("Your internal review request has been sent on " \
                           "its way.")
      else
        flash[:notice] = _("Your follow up message has been sent on its way.")
      end

      @outgoing_message.info_request.reopen_to_new_responses
    ensure
      # Ensure DB is updated to isolate potential templating issues
      # from impacting delivery status information.
      @outgoing_message.save!
    end

    followup_deadline_notice if @outgoing_message.status == 'sent'
  end

  # Put the full letter in :body for duplicate checks; keep the typed middle in
  # @followup_letter to re-render if rejected.
  def put_letter_in_body
    posted = params[:outgoing_message]
    if posted.respond_to?(:key?) && posted.key?(:letter)
      @followup_letter = posted[:letter]
    end
    middle = if @internal_review &&
                Deadlines::FollowupLetter.scottish?(@info_request) &&
                params.key?(:review_reason)
               Deadlines::FollowupLetter.scottish_review(@info_request,
                                                         params[:review_reason],
                                                         params[:review_more])
             else
               @followup_letter
             end
    return unless middle && @user

    rest = if posted.respond_to?(:to_unsafe_h)
             posted.to_unsafe_h.except('letter')
           else
             {}
           end
    body = Deadlines::FollowupLetter.join(middle,
                                          @info_request,
                                          @incoming_message,
                                          @internal_review,
                                          @user.name)
    params[:outgoing_message] =
      ActionController::Parameters.new(rest.merge('body' => body))
  end

  def followup_deadline_notice
    # rubocop:disable Rails/ActionControllerFlashBeforeRender -- called from send_followup before redirect_to
    flash[:notice] =
      if @outgoing_message.what_doing == 'internal_review'
        due = Deadlines::Stage.computed_due_on(@info_request.reload, 'review')
        [
          _('Review asked.'),
          due && _('They should reply by {{date}}.',
                   date: I18n.l(due, format: '%-d %B').html_safe)
        ].compact.join(' ')
      else
        _('Reply sent. If they asked you something, their 20 working days ' \
          'start again today.')
      end
    # rubocop:enable Rails/ActionControllerFlashBeforeRender
  end

  # Intentionally omits can?(:read, @incoming_message) so requesters can follow
  # up on an admin-hidden reply. Request :read and ownership checks still run;
  # hidden content, sender and subject are withheld (followups_no_quotes_spec).
  def set_incoming_message
    return if params[:incoming_message_id].nil?

    @incoming_message = IncomingMessage.find_by!(
      id: params[:incoming_message_id],
      info_request_id: @info_request.id
    )
  end

  def set_info_request
    if current_user
      @info_request = current_user.info_requests.
        find_by(url_title: params[:request_url_title])
    end

    @info_request ||= InfoRequest.
      find_by!(url_title: params[:request_url_title])

    # Reject unreadable requests before authenticate's sign-in prompt can leak
    # the authority name.
    return unless cannot?(:read, @info_request)

    render_hidden
  end

  def set_last_request_data
    remember_last_request(@info_request)
  end

  def set_outgoing_message
    @outgoing_message = OutgoingMessage.new(outgoing_message_params)
    @outgoing_message.add_signature(@user.name) if @user
  end

  def set_refusal_advice
    @refusal_advice = RefusalAdvice.default(
      @info_request,
      internal_review: @internal_review,
      user: current_user
    )
  end

  def set_params
    @is_owning_user = can?(:follow_up, @info_request)
    @gone_postal = params[:gone_postal]
    @gone_postal = false unless @is_owning_user
    set_postal_addresses if @gone_postal
    @collapse_quotes = !params[:unfold]
  end

  def set_postal_addresses
    @postal_email = @info_request.postal_email
    @postal_email_name = @info_request.postal_email_name
  end
end
