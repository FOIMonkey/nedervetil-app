require 'production_safety'

if Rails.env.production?
  ProductionSafety.check_admin_auth!

  # After the app is initialised, so the secret is the one Rails resolved.
  # SECRET_KEY_BASE_DUMMY is Rails' own way of precompiling assets without a
  # secret; it never serves a request.
  Rails.application.config.after_initialize do
    if ENV['SECRET_KEY_BASE_DUMMY'].blank?
      ProductionSafety.check_secret!(Rails.application.secret_key_base)
    end
  end
end
