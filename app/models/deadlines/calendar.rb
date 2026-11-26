module Deadlines
  # Regime-aware working-day calendar: UK bank holidays for FOIA/EIR (FOIA
  # s.10(6), EIR reg 2(1)); Scotland only for FOISA/EIR(S) (FOISA s.73).
  # Falls back to core's Holiday table beyond BankHolidays.last_day.
  module Calendar
    UnsupportedCalendar = Class.new(StandardError)

    module_function

    def validate_configuration!
      return if AlaveteliConfiguration.working_or_calendar_days == 'working'

      raise UnsupportedCalendar,
            'Request deadlines require WORKING_OR_CALENDAR_DAYS: working'
    end

    # Enforces WORKING_OR_CALENDAR_DAYS=working (see doc/FORK.md).
    def due_date_for(request, from:, days:)
      validate_configuration!
      working_days_after(from, days, Deadlines.regime(request))
    end

    def holiday?(day, regime = nil)
      return Holiday.holidays.include?(day) if day > BankHolidays.last_day
      return BankHolidays.scotland.include?(day) if Deadlines.scottish?(regime)

      BankHolidays.uk.include?(day) || Holiday.holidays.include?(day)
    end

    def working_day?(day, regime = nil)
      !day.saturday? && !day.sunday? && !holiday?(day, regime)
    end

    def working_days_after(date, days, regime = nil)
      day = date.to_date
      counted = 0
      while counted < days
        day += 1
        counted += 1 if working_day?(day, regime)
      end
      day
    end

    def working_days_late(due_on, today = Time.zone.today, regime = nil)
      return 0 unless due_on && today > due_on

      working_days_between(due_on, today, regime)
    end

    # Working days in (from, to], computed arithmetically via binary search.
    def working_days_between(from, to, regime = nil)
      return 0 unless from && to && to > from

      weeks, rest = (to - from).to_i.divmod(7)
      weekdays = (weeks * 5) +
                 (1..rest).count { |i| (from + (weeks * 7) + i).on_weekday? }
      list = holidays(regime)
      weekdays - ((list.bsearch_index { |day| day > to } || list.size) -
                  (list.bsearch_index { |day| day > from } || list.size))
    end

    # Rebuilt whenever core reloads its holidays.
    def holidays(regime)
      core = Holiday.holidays
      unless @holidays && @holidays[:core].equal?(core)
        @holidays = { core: core }
      end
      @holidays[Deadlines.scottish?(regime)] ||=
        (BankHolidays.uk | BankHolidays.scotland | core).select do |day|
          !day.saturday? && !day.sunday? && holiday?(day, regime)
        end.sort.freeze
    end
  end
end
