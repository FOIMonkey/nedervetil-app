# Copyright (c) 2008 UK Citizens Online Democracy. All rights reserved.
# Email: hello@mysociety.org; WWW: http://www.mysociety.org/

# Calculates and displays the FOI due date and skipped public holidays for a
# given start date via /due_date/:holiday.
class HolidayController < ApplicationController
  # This will be tidied up into a proper calendar display etc. For now
  # we have a very basic page that allows us to see what a due date will
  # be given a start date. This isn't exposed anywhere yet.
  def due_date
    return unless params[:holiday]

    @request_date = request_date
    @due_date = Holiday.due_date_from(
      @request_date,
      AlaveteliConfiguration.reply_late_after_days,
      AlaveteliConfiguration.working_or_calendar_days
    )
    @skipped =
      Holiday.
        where(['day >= ? AND day <= ?',
               @request_date.strftime("%F"),
               @due_date.strftime("%F")]).to_a.collect(&:day).sort
  end

  private

  # The date in the address. Anything else is a page that isn't there.
  def request_date
    Date.strptime(params[:holiday])
  rescue Date::Error
    raise ActiveRecord::RecordNotFound
  end
end
