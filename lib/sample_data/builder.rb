require 'active_support/testing/time_helpers'

module SampleData
  # Creates sample requests, replies and status changes through core models and
  # mailers at backdated timestamps.
  class Builder
    include ActiveSupport::Testing::TimeHelpers

    def initialize(now = Time.zone.now)
      @now = now.change(hour: 10)
    end

    def on(days_ago, hour: 10, &block)
      travel_to(@now - days_ago.days + (hour - 10).hours, &block)
    end

    # raw: the text is the whole letter, with no salutation or sign-off.
    def send_request(user, body, title, text, raw: false, law_used: nil)
      request = InfoRequest.new(title: title, user: user, public_body: body)
      request.law_used = law_used if law_used
      letter = OutgoingMessage.new(status: 'ready',
                                   message_type: 'initial_request',
                                   what_doing: 'normal_sort',
                                   body: raw ? text : letter(body, text, user))
      request.outgoing_messages << letter
      request.save!
      deliver(OutgoingMailer.initial_request(request, letter), letter)
      request
    end

    def follow_up(request, text, review: false)
      request.reload
      incoming = request.incoming_messages.last
      message = OutgoingMessage.new(
        info_request: request,
        status: 'ready',
        message_type: 'followup',
        what_doing: review ? 'internal_review' : 'normal_sort',
        incoming_message_followup: incoming,
        body: letter(request.public_body, text, request.user)
      )
      message.save!
      deliver(OutgoingMailer.followup(request, message, incoming), message)
      request.reload
    end

    # files: [filename, content type, bytes]
    def reply(request, text, ref:, files: [])
      body = request.public_body
      mail = Mail.new
      mail.from = "Information Requests <#{body.request_email}>"
      mail.to = request.incoming_email
      mail.subject = "RE: Freedom of Information request - #{request.title} " \
                     "[#{ref}]"
      mail.date = Time.zone.now
      mail.message_id = "<#{SecureRandom.hex(10)}@" \
                        "#{body.request_email.split('@').last}>"
      text = "Dear #{request.user.name},\n\nOur reference: #{ref}\n\n" \
             "#{text}\n\nInformation Requests\n#{body.name}\n"
      if files.empty?
        mail.content_type = 'text/plain; charset=UTF-8'
        mail.body = text
      else
        mail.text_part = Mail::Part.new do
          content_type 'text/plain; charset=UTF-8'
          body text
        end
        files.each do |name, type, bytes|
          mail.attachments[name] = { mime_type: type, content: bytes }
        end
      end
      request.receive(Mail.from_source(mail.encoded))
      SampleData.run_local_jobs
      message = request.reload.incoming_messages.order(:id).last
      raise "No reply received for #{request.title}" unless message

      message
    end

    def status(request, state)
      request.reload.set_described_state(state, request.user)
      request
    end

    private

    def letter(body, text, user)
      "Dear #{body.name},\n\n#{text}\n\nYours faithfully,\n\n#{user.name}"
    end

    def deliver(mail, message)
      sent = mail.deliver_now
      domain = AlaveteliConfiguration.incoming_email_domain
      id = sent.message_id.presence || "#{SecureRandom.hex(10)}@#{domain}"
      message.record_email_delivery(sent.to_addrs.join(', '), id)
    end
  end
end
