# Copyright (c) 2007 UK Citizens Online Democracy. All rights reserved.
# Email: hello@mysociety.org; WWW: http://www.mysociety.org/

# Sends request alerts (responses, admin notices, bounces, synthetic replies)
# and ingests raw inbound mail into Action Mailbox via .receive.
class RequestMailer < ApplicationMailer
  include AlaveteliFeatures::Helpers

  before_action :set_footer_template, only: :new_response

  # Used when an FOI officer uploads a response from their web browser - this is
  # the "fake" email used to store in the same format in the database as if they
  # had emailed it.
  def fake_response(info_request, from_user, message_body, attachment_name, attachment_content)
    @message_body = message_body

    if !attachment_name.nil? && !attachment_content.nil?
      content_type = AlaveteliFileTypes.filename_to_mimetype(attachment_name) ||
                     'application/octet-stream'

      attachments[attachment_name] = { content: attachment_content,
                                       content_type: content_type }
    end

    mail(from: from_user.name_and_email,
         to: info_request.incoming_name_and_email,
         subject: info_request.email_subject_followup(html: false))
  end

  # Incoming message arrived for a request, but new responses have been stopped.
  def stopped_responses(info_request, email)
    headers(
      # we don't care about bounces, likely from spammers
      'Return-Path' => blackhole_email,
      'Auto-Submitted' => 'auto-replied' # http://tools.ietf.org/html/rfc3834
    )

    @info_request = info_request
    @contact_email = AlaveteliConfiguration.contact_email

    mail(to: email.from_addrs[0].to_s,
         from: contact_from_name_and_email,
         reply_to: contact_from_name_and_email,
         subject: _("Your response to an FOI request was not delivered"))
  end

  # An FOI response is outside the scope of the system, and needs admin
  # attention
  def requires_admin(info_request, set_by = nil, message = "")
    user = set_by || info_request.user
    @reported_by = user
    @url = request_url(info_request)
    @info_request = info_request
    @message = message

    set_reply_to_headers('Reply-To' => user.name_and_email)

    # From is an address we control so that strict DMARC senders don't get
    # refused
    mail(from: MailHandler.address_from_name_and_email(
      user.name,
                    blackhole_email
    ),
         to: contact_from_name_and_email,
         subject: _("FOI response requires admin ({{reason}}) - " \
                        "{{request_title}}",
                       reason: info_request.described_state,
                       request_title: info_request.title))
  end

  # Tell the requester that a new response has arrived
  def new_response(info_request, incoming_message)
    if summarised_response?(info_request)
      notify_of_response(info_request, incoming_message)
      return
    end

    @incoming_message = incoming_message
    @info_request = info_request

    mail_user(
      info_request.user,
      subject: -> {
        _("New response to your FOI request - {{request_title}}",
          request_title: info_request.title)
      },
      charset: "UTF-8"
    )
  end

  def regulator_pack_ready(info_request, user, token)
    @info_request = info_request
    @download_url = download_regulator_pack_url(token: token)

    mail_user(
      user,
      subject: -> {
        _('Your download is ready - {{request_title}}',
          request_title: info_request.title)
      },
      charset: 'UTF-8'
    )
  end

  def self.receive(inbound_email)
    ActionMailbox::InboundEmail.create_and_extract_message_id!(inbound_email)
  end

  private

  def set_footer_template
    @footer_template = 'default'
  end

  # With AI reading on, a reply waits for its reading and then goes into the
  # requester's summary, so it becomes a notification instead of this email.
  def summarised_response?(info_request)
    IncomingAttention::Effective.active? && info_request.user &&
      info_request.url_title != 'holding_pen' &&
      !info_request.use_notifications?
  end

  def notify_of_response(info_request, incoming_message)
    event = incoming_message.response_event
    return unless event && event.info_request_id == info_request.id
    return if Notification.exists?(user_id: info_request.user_id,
                                   info_request_event_id: event.id)

    info_request.user.notify(event)
  end
end
