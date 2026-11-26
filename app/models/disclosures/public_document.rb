require 'delegate'

module Disclosures
  # Public-safe wrapper around Document that hides private request links.
  class PublicDocument < SimpleDelegator
    def authority
      __getobj__.public_body
    end

    def public_body
      authority
    end

    def kind_label
      Document.kind_label(kind)
    end

    def info_request
      nil
    end

    def incoming_message
      nil
    end

    def info_request_batch
      nil
    end

    def request_siblings
      Document.none
    end

    def batch_siblings
      Document.none
    end
  end
end
