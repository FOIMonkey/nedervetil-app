class InfoRequest
  module ResponseRejection
    # Rejection handler for the bounce action. Emails the sender via
    # RequestMailer.stopped_responses unless the From address is absent or
    # matches the request's own address.
    class Bounce < Base
      def reject(_reason = nil)
        from_address = MailHandler.get_from_address(mail)
        if from_address.nil? ||
           from_address.downcase == info_request.incoming_email.downcase
          # do nothing – can't bounce the mail as there's no address to send it
          # to, or the mail is spoofing the request address, and we'll end up
          # in a loop if we bounce it.
          true
        else
          RequestMailer.stopped_responses(info_request, mail).deliver_now
        end
      end
    end
  end
end
