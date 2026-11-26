# Handles spreading alerts over the day so that we have a more even server load.
module User::SpreadableAlerts
  extend ActiveSupport::Concern

  included do
    after_initialize :set_alert_times
  end

  class_methods do
    # Used for default values of last_daily_track_email
    def random_time_in_last_day
      Time.zone.now - rand(24.hours).seconds
    end
  end

  private

  def set_alert_times
    return unless new_record?

    # make alert emails go out at a random time for each new user, so
    # overall they are spread out throughout the day.
    self.last_daily_track_email = self.class.random_time_in_last_day

    # Make daily summary emails go out at a random time for each new user
    # too, if it's not already set
    self.daily_summary_hour ||= self.class.random_time_in_last_day.hour
    self.daily_summary_minute ||= self.class.random_time_in_last_day.min
  end
end
