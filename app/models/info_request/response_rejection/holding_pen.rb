class InfoRequest
  module ResponseRejection
    # Routes refused mail into the holding pen unless the request already is
    # it. Always returns true so a duplicate mail the holding pen ignores is
    # still treated as rejected by the target request.
    class HoldingPen < Base
      attr_reader :holding_pen

      def initialize(info_request, mail, **)
        super
        @holding_pen = InfoRequest.holding_pen_request
      end

      def reject(reason = nil) # rubocop:disable Naming/PredicateMethod -- an action, not a question
        return false if info_request == holding_pen

        holding_pen.receive(mail, rejected_reason: reason, **inbound_ids)
        true
      end
    end
  end
end
