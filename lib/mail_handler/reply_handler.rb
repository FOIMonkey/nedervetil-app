module MailHandler
  # Used by script/handle-mail-replies.rb to detect permanent bounces and
  # out-of-office auto-replies, record user email bounces and forward other
  # mail to support.
  module ReplyHandler
    def self.permanently_failed_addresses(message)
      if MailHandler.empty_return_path?(message)
        # Some sort of auto-response

        # Check for Exim’s X-Failed-Recipients header
        failed_recipients =
          MailHandler.get_header_string("X-Failed-Recipients", message)
        unless failed_recipients.nil?
          # The X-Failed-Recipients header contains the email address that
          # failed
          # Check for the words "This is a permanent error." in the body, to
          # indicate a permanent failure
          body = MailHandler.get_part_body(message)
          if /This is a permanent error./.match?(body)
            return failed_recipients.split(/,\s*/)
          end
        end

        # Next, look for multipart/report
        if MailHandler.get_content_type(message) == "multipart/report"
          permanently_failed_recipients = delivery_status_failures(message)
          unless permanently_failed_recipients.empty?
            return permanently_failed_recipients
          end
        end
      end

      subject = MailHandler.get_header_string("Subject", message)
      # Then look for the style we’ve seen in WebShield bounces
      # (These do not have a return path of <> in the cases I have seen.)
      if subject == "Returned Mail: Error During Delivery"
        failed = /^\s*---- Failed Recipients ----\s*((?:<[^>]+>\r?\n)+)/.
          match(MailHandler.get_part_body(message))
        return failed[1].scan(/<([^>]+)>/).flatten if failed
      end

      []
    end

    def self.delivery_status_failures(message)
      message.parts.each_with_object([]) do |part, failed|
        unless MailHandler.get_content_type(part) == "message/delivery-status"
          next
        end

        sections = MailHandler.get_part_body(part).split(/\r?\n\r?\n/)
        # The first section is a generic header; subsequent sections
        # represent a particular recipient. Since we
        sections[1..-1].each do |section|
          # Either we couldn’t find the Status field, or it was a
          # transient failure
          break unless section[/^Status: (\d)/, 1] == '5'

          recipient = section[/^Final-Recipient: rfc822;(.+)/, 1]
          failed.push(recipient) if recipient
        end
      end
    end
    private_class_method :delivery_status_failures

    def self.is_oof?(message)
      # Check for out-of-office

      if MailHandler.get_header_string("X-POST-MessageClass", message) ==
         "9; Autoresponder"
        return true
      end

      subject = MailHandler.get_header_string("Subject", message).downcase
      if MailHandler.empty_return_path?(message)
        return true if subject.start_with?("out of office: ",
                                           "automatic reply: ")
      end

      if MailHandler.get_header_string("Auto-Submitted", message) ==
         "auto-generated"
        return true if /out of( the)? office/.match?(subject)
      end

      return true if subject.start_with? "out of office autoreply:"
      return true if ["out of office", "out of office reply"].include?(subject)
      return true if subject.end_with? "is out of the office"

      false
    end

    def self.forward_on(raw_message, message = nil)
      forward_to = get_forward_to_address(message)
      cmd = ['/usr/sbin/sendmail', '-i', '--', forward_to.to_s]
      IO.popen(cmd, 'wb') do |f|
        f.write(raw_message)
        f.close
      end
    end

    def self.get_forward_to_address(_message)
      AlaveteliConfiguration.forward_nonbounce_responses_to
    end

    def self.load_rails
      root = File.expand_path('../..', __dir__)
      require File.join(root, 'config', 'boot')
      require File.join(root, 'config', 'environment')
    end

    def self.record_bounce(email_address, bounce_message)
      load_rails
      User.record_bounce_for_email(email_address, bounce_message)
    end
  end
end
