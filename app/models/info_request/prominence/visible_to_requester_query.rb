class InfoRequest
  module Prominence
    # All requests in a state that would allow the request owner to view them
    # (Ability::RequesterVisible).
    class VisibleToRequesterQuery
      def initialize(relation = InfoRequest)
        @relation = relation
      end

      def call
        @relation.where(
          Ability::RequesterVisible.sql(request: InfoRequest.table_name)
        )
      end
    end
  end
end
