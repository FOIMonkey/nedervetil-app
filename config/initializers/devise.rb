Devise.setup do |config|
  config.mailer_sender = AlaveteliConfiguration.contact_email
  config.parent_controller = 'ApplicationController'
  config.parent_mailer = 'ApplicationMailer'
  config.http_authenticatable = false
  config.mailer = 'AuthenticationMailer'
  require 'devise/orm/active_record'
  config.case_insensitive_keys = [:email]
  config.strip_whitespace_keys = [:email]
  config.password_length = 12..72
  config.stretches = Rails.env.test? ? 4 : 12
  config.paranoid = true
  config.sign_in_after_reset_password = false
  config.sign_in_after_change_password = false
  config.allow_unconfirmed_access_for = 0.days
  config.confirm_within = 1.day
  config.reset_password_within = 1.hour
  # Email change is an explicit authenticated, stepped-up pending action.
  config.reconfirmable = false
  config.timeout_in = 3.hours
  config.skip_session_storage = [:http_auth, :params_auth]
  config.navigational_formats = ['*/*', :html, :turbo_stream]
  config.responder.error_status = :unprocessable_content
  config.responder.redirect_status = :see_other
  config.sign_out_via = [:delete, :post]
  config.otp_allowed_drift = 15
  config.warden do |manager|
    manager.failure_app = ->(env) { Authentication::FailureApp.call(env) }
    manager.default_strategies(scope: :user).replace(
      [:two_factor_backupable, :two_factor_authenticatable]
    )
  end
end
