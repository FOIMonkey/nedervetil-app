module HealthChecks
  module Checks
    # Passes while its block returns true.
    class ConditionCheck
      include HealthChecks::HealthCheckable

      def initialize(args = {}, &block)
        @condition = block
        super(args)
      end

      def ok?
        @condition.call == true
      end
    end
  end
end
