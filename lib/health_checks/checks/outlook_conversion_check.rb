module HealthChecks
  module Checks
    # Runs MailHandler.outlook_self_test to verify msgconvert works in the
    # active mode (cached for KEEP).
    class OutlookConversionCheck
      include HealthChecks::HealthCheckable

      KEEP = 1.minute

      def initialize(args = {})
        super
        @checked_at = nil
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
        if @checked_at.nil? || @checked_at < KEEP.ago
          @result = run
          @checked_at = Time.zone.now
        end
        @result
      end

      def run
        MailHandler.outlook_self_test
        cells = AlaveteliSandbox::Cell.configured?
        [true, cells ? 'msgconvert ran in the mail cell' : 'msgconvert ran']
      rescue StandardError => e
        [false, "#{e.class}: #{e.message}".truncate(300)]
      end
    end
  end
end
