module HealthChecks
  module Checks
    # Runs OfficePackage::Isolated.self_test when sandboxing is required
    # (cached for KEEP).
    class OfficeWorkerCheck
      include HealthChecks::HealthCheckable

      KEEP = 1.minute

      def initialize(args = {})
        super
        @checked_at = nil
        @mutex = Mutex.new
      end

      def ok?
        result.first
      end

      def failure_message
        "#{super}: #{result.last}"
      end

      def success_message
        "#{super}: #{result.last}"
      end

      private

      def result
        @mutex.synchronize do
          if @checked_at.nil? || @checked_at < KEEP.ago
            @result = run
            @checked_at = Time.zone.now
          end
          @result
        end
      end

      def run
        unless AlaveteliSandbox.required?
          return [true, 'Office files are read in this process, as the ' \
                        'sandbox isn’t required']
        end

        OfficePackage::Isolated.self_test
        cells = AlaveteliSandbox::Cell.configured?
        [true, cells ? 'the worker ran in the Office cell' : 'the worker ran']
      rescue StandardError => e
        [false, "#{e.class}: #{e.message}".truncate(300)]
      end
    end
  end
end
