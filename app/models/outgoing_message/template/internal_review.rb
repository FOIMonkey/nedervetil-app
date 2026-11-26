class OutgoingMessage
  module Template
    # Default letter template for an internal review follow-up, pre-filled
    # with standard review wording and a placeholder for complaint details.
    class InternalReview
      def self.details_placeholder
        _('GIVE DETAILS ABOUT YOUR COMPLAINT HERE')
      end

      def body(opts = {})
        assert_required_keys(opts, :public_body_name, :info_request_title, :url)
        template_string(opts)
      end

      def salutation(replacements = {})
        _("Dear {{public_body_name}},", replacements)
      end

      def letter(replacements = {})
        if replacements[:letter]
          "\n\n#{ replacements[:letter] }"
        else
          msg = _("Please pass this on to the person who conducts Freedom " \
                   "of Information reviews.")
          msg += "\n\n"
          msg += _("I am writing to request an internal review of " \
                   "{{public_body_name}}'s handling of my FOI request " \
                   "'{{info_request_title}}'.",
                   replacements)
          msg += "\n\n\n\n"
          msg += " [ #{ self.class.details_placeholder } ]"

          # No link to the request's page: the authority can't open a private
          # request, and already has the emails.
          ActiveSupport::SafeBuffer.new("\n\n") << msg
        end
      end

      def signoff(replacements = {})
        _("Yours faithfully,", replacements)
      end

      private

      def template_string(replacements)
        msg = salutation(replacements)
        msg += letter(replacements)
        msg += "\n\n\n"
        msg += signoff(replacements)
        msg + "\n\n"
      end

      def assert_required_keys(hash, *required_keys)
        required_keys.each do |required_key|
          unless hash.key?(required_key)
            raise ArgumentError, "Missing required key: #{required_key}"
          end
        end
      end
    end
  end
end
