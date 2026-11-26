module HealthChecks
  module Checks
    # Passes while the timestamp returned by its block falls within the
    # configured period (default 1 day).
    class PeriodCheck
      include HealthChecks::HealthCheckable

      attr_reader :period, :subject

      def initialize(args = {}, &block)
        @period = args.fetch(:period) { 1.day }
        @subject = block
        super(args)
      end

      def failure_message
        "#{ super }: #{ value || 'never' }"
      end

      def success_message
        "#{ super }: #{ value }"
      end

      # A subject with no time yet (an empty table) fails instead of raising.
      def ok?
        time = value
        time.present? && time >= period.ago
      end

      private

      def value
        subject.call
      end
    end
  end
end
