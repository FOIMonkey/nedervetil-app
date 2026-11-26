# Default response-lateness thresholds for InfoRequest, reading
# reply_late_after_days and reply_very_late_after_days from configuration.
class DefaultLateCalculator
  def self.description
    %q(Defaults controlled by config/general.yml)
  end

  def reply_late_after_days
    AlaveteliConfiguration.reply_late_after_days
  end

  def reply_very_late_after_days
    AlaveteliConfiguration.reply_very_late_after_days
  end
end
