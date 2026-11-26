require 'mail'
require 'action_mailbox/mail_ext'
require 'normalize_string'

module Mail
  # Wraps Mail::Message#to, #cc and #bcc so unparseable address headers return
  # nil rather than a raw string.
  class Message
    alias old_to to
    alias old_cc cc
    alias old_bcc bcc

    def clean_addresses(old_method, val)
      old_result = send(old_method, val)
      old_result.instance_of?(Mail::AddressContainer) ? old_result : nil
    end

    def to(val = nil)
      clean_addresses :old_to, val
    end

    def cc(val = nil)
      clean_addresses :old_cc, val
    end

    def bcc(val = nil)
      clean_addresses :old_bcc, val
    end
  end
end

module MailHandler
  # Reads email headers and formats outgoing addresses in-process without
  # parsing the message body.
  module Headers
    def get_subject(mail)
      subject = mail.subject
      convert_string_to_utf8(subject).string if subject
    end

    def first_from(mail)
      return unless mail[:from]

      begin
        mail[:from].addrs[0]
        mail[:from].decoded
        mail[:from].addrs[0]
      rescue
        mail[:from].value
      end
    end

    def get_from_address(mail)
      first_from = first_from(mail)
      return unless first_from

      if first_from.is_a?(String)
        nil
      else
        first_from.address
      end
    end

    def get_from_name(mail)
      first_from = first_from(mail)
      return unless first_from

      if first_from.is_a?(String)
        nil
      else
        first_from.display_name || nil
      end
    end

    def get_all_addresses(mail, include_invalid: false)
      addrs = []
      addrs << mail.to
      addrs << mail[:to].try(:value) if mail.to.nil? && include_invalid
      addrs << mail.cc
      addrs << mail[:cc].try(:value) if mail.cc.nil? && include_invalid
      addrs << mail.bcc
      addrs << mail[:bcc].try(:value) if mail.bcc.nil? && include_invalid
      addrs << (mail['envelope-to'] ? mail['envelope-to'].value.to_s : nil)
      addrs << get_emails_within_received_headers(mail)
      addrs.flatten.compact.uniq
    end

    def empty_return_path?(mail)
      return false if mail['return-path'].nil?
      return true if mail['return-path'].value.blank?

      false
    end

    def get_auto_submitted(mail)
      mail['auto-submitted'] ? mail['auto-submitted'].value : nil
    end

    def address_from_name_and_email(name, email)
      unless MySociety::Validate.is_valid_email(email)
        raise "invalid email " + email +
              " passed to address_from_name_and_email"
      end
      return Mail::Address.new(email.dup).to_s if name.nil?

      address = Mail::Address.new
      address.display_name = name.dup
      address.address = email.dup
      address.to_s
    end

    def address_from_string(string)
      mail = Mail.new
      mail.from = string
      mail.from[0]
    end

    def get_emails_within_received_headers(email)
      received_headers = Array(email['Received'])
      return [] if received_headers.empty?

      received_headers.map(&:to_s).
        join(' ').
        scan(MySociety::Validate.email_find_regexp).
        flatten
    end
  end
end
