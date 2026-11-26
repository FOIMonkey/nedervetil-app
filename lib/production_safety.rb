# Boot-time production guards (config/initializers/production_safety.rb);
# raises to refuse boot if insecure secret or test auth bypass is active.
module ProductionSafety
  module_function

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
end
