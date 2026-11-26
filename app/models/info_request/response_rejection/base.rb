class InfoRequest
  module ResponseRejection
    # Base rejection handler, used directly for blackhole and discard actions.
    # Silently drops the refused email without bouncing or storing it.
    class Base
      attr_reader :info_request, :mail, :inbound_ids

      # inbound_ids carries the inbound email's message_id and checksum.
      def initialize(info_request, mail, **inbound_ids)
        @info_request = info_request
        @mail = mail
        @inbound_ids = inbound_ids
      end

      def reject(_reason = nil) # rubocop:disable Naming/PredicateMethod -- an action, not a question
        true
      end
    end
  end
end
