# Splits a start-to-finish date range into calendar-quarter [start, end] pairs
# for the statistics rake tasks.
module DateQuarter
  extend self

  def quarters_between(start_at, finish_at)
    results = []

    quarter_start = start_at.beginning_of_quarter
    quarter_end   = start_at.end_of_quarter

    while quarter_end <= finish_at.end_of_quarter
      # Collect these
      results << [quarter_start, quarter_end]

      # Update dates
      quarter_start = quarter_end + 1.second
      quarter_end = quarter_start.end_of_quarter
    end

    results
  end
end
