class InfoRequest
  module Prominence
    # Reads an InfoRequest's prominence attribute and reports whether it is
    # requester_only. Returned by InfoRequest#prominence(decorate: true).
    class Calculator
      def initialize(info_request)
        @info_request = info_request
      end

      # Is this request visible only to admins and the requester?
      def is_requester_only?
        to_s == 'requester_only'
      end

      def to_s
        @info_request.read_attribute(:prominence)
      end
    end
  end
end
