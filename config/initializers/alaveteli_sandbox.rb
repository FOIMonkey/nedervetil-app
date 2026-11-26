# Refuse to boot with an invalid SANDBOX_CONVERTERS, or with settings it can't
# support, and record each process's effective mode. It is logged as a
# warning so that services running at RAILS_LOG_LEVEL=warn still record it.
Rails.application.config.after_initialize do
  AlaveteliSandbox.boot
end
