class InfoRequest
  module State
    # Query for InfoRequest.complete: selects classified requests in finished
    # states (not_held, rejected, successful, partially_successful or
    # user_withdrawn).
    class CompleteQuery
      def initialize(relation = InfoRequest)
        @relation = relation
      end

      def call
        @relation.where(
          described_state: %w[
            not_held rejected successful partially_successful user_withdrawn
          ],
          awaiting_description: false
        )
      end
    end
  end
end
