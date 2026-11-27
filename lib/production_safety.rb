# Boot-time production guards (config/initializers/production_safety.rb);
# raises to refuse boot if insecure secret or test auth bypass is active.
module ProductionSafety
  BOOTSTRAP_TASKS = %w[config_files:set_credentials].freeze

  module_function

  def bootstrapping_credentials?(tasks = current_rake_tasks)
    (Array(tasks) & BOOTSTRAP_TASKS).any?
  end

  def current_rake_tasks
    return [] unless defined?(Rake) && Rake.respond_to?(:application)

    Rake.application.top_level_tasks
  end

  # Checks Rails' resolved secret (ENV/credentials) via default_secret?.
  def check_secret!(secret)
    return unless AlaveteliConfiguration.default_secret?(secret)

    raise 'SECRET_KEY_BASE is the published default or shorter than 64 ' \
          'characters. Set a long random one (bin/rails secret) in ' \
          'config/general.yml or the credentials before starting production.'
  end

  def check_admin_auth!
    return unless AlaveteliConfiguration.skip_admin_auth

    raise 'SKIP_ADMIN_AUTH is on. It makes every visitor an admin and is ' \
          'for the test environment only.'
  end

  def check_incoming_email_secret!(
    secret = AlaveteliConfiguration.incoming_email_secret
  )
    return unless AlaveteliConfiguration.default_incoming_email_secret?(secret)

    raise 'INCOMING_EMAIL_SECRET is the shipped default, the example ' \
          'placeholder, or shorter than 32 characters. Set a random secret ' \
          'in config/general.yml before starting production.'
  end

  def check_encryption_keys!(encryption = ActiveRecord::Encryption.config)
    keys = [encryption.primary_key, encryption.deterministic_key,
            encryption.key_derivation_salt]
    return if keys.all? { |key| Array(key).last.to_s.length >= 16 }

    raise 'ActiveRecord::Encryption keys are missing or shorter than 16 ' \
          'characters. Run `bin/rails config_files:set_credentials` or set ' \
          'active_record_encryption in credentials before starting production.'
  end
end
