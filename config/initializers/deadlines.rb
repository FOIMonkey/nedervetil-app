# Check the configured calendar once at boot, before requests can be served.
# Do not use to_prepare: tests can override configuration after boot, and the
# runtime guard still protects recalculation (including legacy NULL dates).
Rails.application.config.after_initialize do
  Deadlines::Calendar.validate_configuration!
end
