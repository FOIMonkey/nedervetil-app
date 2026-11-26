module Deadlines
  # When a reply is due to a request an authority received on a given day,
  # for the help pages' deadline checker. It counts as request deadlines do
  # (Calendar), for a day typed in by a visitor, not for a request.
  class Checker
    DATE = /\A\d{4}-\d{2}-\d{2}\z/

    attr_reader :received

    # `received` is the date as a date field sends it; `where` is 'scotland'
    # for an authority under the Scottish Act.
    def initialize(received, where = nil)
      @typed = !received.nil?
      @received = parse(received)
      @regime = where == 'scotland' && self.class.scotland? ? 'foisa' : 'foi'
    end

    # Bank holidays differ in Scotland only when a theme's data says so.
    def self.scotland?
      BankHolidays.scotland.any?
    end

    # A date field that was cleared and sent still asks.
    def asked? = @typed

    def scottish? = Deadlines.scottish?(@regime)

    def days = AlaveteliConfiguration.reply_late_after_days

    def due
      return unless received

      @due ||= Calendar.working_days_after(received, days, @regime)
    end

    # With bank holiday data, a date outside the years it covers would count
    # bank holidays as working days.
    def known?
      return false unless due

      holidays = BankHolidays.uk
      holidays.empty? || (received >= holidays.min && due <= holidays.max)
    end

    private

    def parse(text)
      Date.iso8601(text) if text.to_s.match?(DATE)
    rescue Date::Error
      nil
    end
  end
end
