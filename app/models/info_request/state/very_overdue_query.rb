class InfoRequest
  module State
    # Query for InfoRequest.very_overdue: selects classified waiting_response
    # requests past date_very_overdue_after.
    class VeryOverdueQuery
      def initialize(relation = InfoRequest)
        @relation = relation
      end

      def call
        @relation.
          where(described_state: ['waiting_response']).
            where("date_very_overdue_after < ?", Time.zone.now.to_date).
              where(awaiting_description: false)
      end
    end
  end
end
