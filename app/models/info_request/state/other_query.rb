class InfoRequest
  module State
    # Query for InfoRequest.other: selects classified requests in postal,
    # internal review, appeal, error or administrator-managed states.
    class OtherQuery
      def initialize(relation = InfoRequest)
        @relation = relation
      end

      def call
        @relation.where(
          described_state: %w[
            gone_postal internal_review under_appeal error_message
            requires_admin attention_requested vexatious not_foi
          ],
          awaiting_description: false
        )
      end
    end
  end
end
