module HealthChecks
  module Checks
    # Runs MailHandler::Reading.self_test in the active execution mode
    # (cached for KEEP to avoid starting a read on every poll).
    class MailReadCheck
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
        MailHandler::Reading.self_test
        [true, "read a tiny mail in #{where}"]
      rescue StandardError => e
        [false, "#{e.class}: #{e.message}".truncate(300)]
      end

      def where
        return 'the mail cell' if AlaveteliSandbox::Cell.configured?

        AlaveteliSandbox.required? ? 'the sandbox' : 'this process'
      end
    end
  end
end
