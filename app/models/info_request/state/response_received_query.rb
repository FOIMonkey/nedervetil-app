class InfoRequest
  module State
    # Query for InfoRequest.response_received: selects requests with an
    # unclassified reply (awaiting_description is true).
    class ResponseReceivedQuery
      def initialize(relation = InfoRequest)
        @relation = relation
      end

      def call
        @relation.where(awaiting_description: true)
      end
    end
  end
end
