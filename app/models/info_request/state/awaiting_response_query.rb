class InfoRequest
  module State
    # Query for InfoRequest.awaiting_response (in_progress): selects
    # classified waiting_response requests whose due date is in the future.
    class AwaitingResponseQuery
      def initialize(relation = InfoRequest)
        @relation = relation
      end

      def call
        @relation.
          where(described_state: 'waiting_response',
                awaiting_description: false).
            where("date_response_required_by > ?", Time.zone.now.to_date)
      end
    end
  end
end
