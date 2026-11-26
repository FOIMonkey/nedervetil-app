class InfoRequest
  module State
    # Query for InfoRequest.clarification_needed: selects classified requests
    # in the waiting_clarification state.
    class ClarificationNeededQuery
      def initialize(relation = InfoRequest)
        @relation = relation
      end

      def call
        @relation.where(described_state: 'waiting_clarification',
                        awaiting_description: false)
      end
    end
  end
end
