module AuthorityFeeds
  # Whether a figure is still the newest its publisher could have released
  # (only then can it go to the top of a page).
  module Freshness
    # After a period ends, how long until the next period's figures are due.
    CURRENT_FOR = { 'daily' => 3.days,
                    'weekly' => 14.days,
                    'monthly' => 62.days,
                    'quarterly' => 6.months,
                    'yearly' => 15.months }.freeze
    RECENT = 1.year

    module_function

    # Parses financial years ("2025-26", Mar 31), years, or months ("2026-09").
    def period_end(period, updates)
      text = period.to_s
      if updates == 'yearly'
        if (year = text[/\A(\d{4})-\d{2}\z/, 1])
          Date.new(year.to_i + 1, 3, 31)
        elsif text.match?(/\A\d{4}\z/)
          Date.new(text.to_i, 12, 31)
        end
      elsif (month = text.match(/\A(\d{4})-(\d{2})\z/))
        Date.new(month[1].to_i, month[2].to_i, -1)
      end
    rescue Date::Error
      nil
    end

    def current?(period, updates, today: Date.current)
      ends = period_end(period, updates)
      ends.present? && today <= ends + CURRENT_FOR.fetch(updates)
    end

    def recent?(date, today: Date.current)
      date.present? && date > today - RECENT
    end
  end
end
