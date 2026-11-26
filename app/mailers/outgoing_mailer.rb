# Copyright (c) 2009 UK Citizens Online Democracy. All rights reserved.
# Email: hello@mysociety.org; WWW: http://www.mysociety.org/

# NOTE: The layout for this wraps messages by lines rather than (blank line
# separated) paragraphs, as is the convention for all the other mailers. This
# turned out to fit better with user expectations when formatting messages.
#
# TODO: The other mail templates are written to use blank line separated
# paragraphs. They could be rewritten, and the wrapping method made uniform
# throughout the application.

# Sends initial FOI requests and follow-up messages to public authorities on
# behalf of requesters, and computes follow-up recipients, subjects and
# Message-ID headers.
class OutgoingMailer < ApplicationMailer
  # Email to public body requesting info
  def initial_request(info_request, outgoing_message)
    @info_request = info_request
    @outgoing_message = outgoing_message
    @contact_email = AlaveteliConfiguration.contact_email
    headers["message-id"] = OutgoingMailer.id_for_message(@outgoing_message)

    mail(from: @outgoing_message.from,
         to: @outgoing_message.to,
         subject: @outgoing_message.subject)
  end

  # Later message to public body regarding existing request
  def followup(info_request, outgoing_message, incoming_message_followup)
    @info_request = info_request
    @outgoing_message = outgoing_message
    @incoming_message_followup = incoming_message_followup
    @contact_email = AlaveteliConfiguration.contact_email
    headers["message-id"] = OutgoingMailer.id_for_message(@outgoing_message)

    mail(from: @outgoing_message.from,
         to: @outgoing_message.to,
         subject: @outgoing_message.subject)
  end

  # Used in the preview of followup
  def self.name_for_followup(info_request, incoming_message_followup)
    if incoming_message_followup.nil? ||
       !incoming_message_followup.followup_to_sender?
      info_request.public_body.name
    else
      # calling safe_from_name from so censor rules are run
      incoming_message_followup.safe_from_name || info_request.public_body.name
    end
  end

  # Used when making list of followup places to remove duplicates
  def self.email_for_followup(info_request, incoming_message_followup)
    if incoming_message_followup.nil? ||
       !incoming_message_followup.followup_to_sender?
      info_request.recipient_email
    else
      incoming_message_followup.from_email
    end
  end

  # Subject to use for followup
  def self.subject_for_followup(info_request, outgoing_message, options = {})
    html = options[:html] || false
    if outgoing_message.what_doing == 'internal_review'
      values = {
        email_subject: info_request.email_subject_request(html: html)
      }
      if html
        _("Internal review of {{email_subject}}", values)
      else
        PlainTextTranslation._("Internal review of {{email_subject}}", values)
      end
    else
      info_request.email_subject_followup(
        incoming_message: outgoing_message.incoming_message_followup,
        html: html
      )
    end
  end

  # Whether we have a valid email address for a followup
  def self.is_followupable?(info_request, incoming_message_followup)
    if incoming_message_followup.nil? ||
       !incoming_message_followup.followup_to_sender?
      info_request.recipient_email_valid_for_followup?
    else
      # email has been checked in incoming_message_followup.followup_to_sender?
      # above
      true
    end
  end

  # Message-ID to use
  def self.id_for_message(outgoing_message)
    message_id = "ogm-" + outgoing_message.id.to_s
    t = Time.zone.now
    message_id += "+" + format('%08x%05x-%04x', t.to_i, t.tv_usec, rand(0xffff))
    message_id += "@" + AlaveteliConfiguration.incoming_email_domain
    "<" + message_id + ">"
  end
end
