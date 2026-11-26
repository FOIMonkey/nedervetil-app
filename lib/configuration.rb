require File.dirname(__FILE__) + '/../vendor/mysociety/rblib/config'

# Load initial mySociety config
if ENV["RAILS_ENV"] == "test"
  MySociety::Config.set_file(
    File.join(File.dirname(__FILE__), '..', 'config', 'test'), true
  )
else
  MySociety::Config.set_file(
    File.join(File.dirname(__FILE__), '..', 'config', 'general'), true
  )
end
MySociety::Config.load_default

# TODO: Make this return different values depending on the current rails
# environment

# Exposes site settings from config/general.yml (or config/test.yml and
# ALAVETELI_* env vars in test) with defaults, secret-strength checks and a
# filtered hash for Admin::DebugController.
module AlaveteliConfiguration
  # WARNING: AlaveteliConfiguration is rendered to admin users in
  #          Admin::DebugController.
  #
  # Ensure any sensitive values match this pattern, or add to the pattern if
  # adding a new value that doesn't fit.
  mattr_accessor :sensitive_key_patterns,
                 default: /SECRET|PASSWORD|LICENSE_KEY|TOKEN|_KEY\z/

  unless const_defined?(:DEFAULTS)

    # rubocop:disable Layout/LineLength
    DEFAULTS = {
      # Legacy accessors retained for older provisioning checks. These settings
      # no longer authenticate anyone; emergency login has been removed.
      ADMIN_PASSWORD: '',
      ADMIN_USERNAME: '',
      ATTACHMENT_MANAGEMENT_DRAFT_HOURS: 4,
      ATTACHMENT_MANAGEMENT_PREVIEW_HOURS: 4,
      ATTACHMENT_MANAGEMENT_REQUESTER_ACCESS: 'redact',
      AUTHORITY_MUST_RESPOND: true,
      AVAILABLE_LOCALES: 'en',
      BLACKHOLE_PREFIX: 'do-not-reply-to-this-address',
      BLOCK_SPAM_REQUESTS: false,
      BLOCK_SPAM_SIGNINS: false,
      BLOCK_SPAM_SIGNUPS: false,
      CACHE_FRAGMENTS: true,
      CONTACT_EMAIL: 'contact@localhost',
      CONTACT_NAME: 'Alaveteli',
      CONVERTERS_DISABLED: false,
      DEBUG_RECORD_MEMORY: false,
      DEFAULT_LOCALE: 'en',
      DISABLE_EMERGENCY_USER: true,
      DISCLOSURES_OCR: true,
      DISCLOSURES_PII_CHECK: 'off',
      DISCLOSURES_PII_CHECK_ENDPOINT: '',
      DISCLOSURES_PII_CHECK_ENTITIES: [],
      DISCLOSURES_REMOVE_OFFICE_METADATA: false,
      DISCLOSURES_REQUESTER_EDITING: true,
      DISCLOSURES_REVIEW_REQUESTER_REDACTIONS: true,
      DOMAIN: 'localhost:3000',
      DONATION_URL: '',
      ENABLE_TWO_FACTOR_AUTH: false,
      ENFORCE_REQUEST_LIMITS: true,
      EXCEPTION_NOTIFICATIONS_FROM: 'errors@localhost',
      EXCEPTION_NOTIFICATIONS_TO: 'user-support@localhost',
      FACEBOOK_USERNAME: '',
      FORCE_REGISTRATION_ON_NEW_REQUEST: false,
      FORCE_SSL: true,
      FORWARD_NONBOUNCE_RESPONSES_TO: 'user-support@localhost',
      GA_CODE: '',
      INCOMING_ATTENTION_ANONYMISER_ENDPOINT: '',
      INCOMING_ATTENTION_BACKFILL_RECEIVED_AFTER: '',
      INCOMING_ATTENTION_ENABLED: false,
      INCOMING_ATTENTION_ENDPOINT: '',
      INCOMING_EMAIL_DOMAIN: 'localhost',
      INCOMING_EMAIL_PREFIX: 'foi+',
      INCOMING_EMAIL_SECRET: 'dummysecret',
      INCOMING_EMAIL_SPAM_ACTION: false,
      INCOMING_EMAIL_SPAM_HEADER: 'X-Spam-Score',
      INCOMING_EMAIL_SPAM_THRESHOLD: false,
      INCOMING_OUTCOME_MODE: 'off',
      INCOMING_OUTCOME_OCR: false,
      INCOMING_OUTCOME_STRICT_DOCUMENTS: false,
      ISO_COUNTRY_CODE: 'GB',
      MTA_LOG_PATH: '/var/log/exim4/exim-mainlog-*',
      MTA_LOG_TYPE: 'exim',
      OTHER_FOI_SITE_NAME: '',
      OTHER_FOI_SITE_URL: '',
      OVERRIDE_ALL_PUBLIC_BODY_REQUEST_EMAILS: '',
      POP_MAILER_ADDRESS: 'localhost',
      POP_MAILER_ENABLE_SSL: true,
      POP_MAILER_PASSWORD: '',
      POP_MAILER_PORT: 995,
      POP_MAILER_USER_NAME: '',
      PRODUCTION_MAILER_DELIVERY_METHOD: 'sendmail',
      PRODUCTION_MAILER_RETRIEVER_METHOD: 'passive',
      PUBLIC_BODY_LIST_FALLBACK_TO_DEFAULT_LOCALE: false,
      RAW_EMAILS_LOCATION: 'files/raw_emails',
      READ_ONLY: '',
      READ_ONLY_FEATURES: [],
      REPLY_LATE_AFTER_DAYS: 20,
      REPLY_VERY_LATE_AFTER_DAYS: 40,
      RESTRICT_NEW_RESPONSES_ON_OLD_REQUESTS_AFTER_MONTHS: 6,
      SANDBOX_BWRAP: '/usr/bin/bwrap',
      SANDBOX_CONVERTERS: 'off',
      SANDBOX_MAIL_CELL: '',
      SANDBOX_OFFICE_CELL: '',
      SANDBOX_PDF_CELL: '',
      SANDBOX_VOLUME: '/run/alaveteli-convert',
      SECRET_KEY_BASE: 'this default is insecure as code is open source, please override for live sites in config/general; this will do for local development',
      SITE_NAME: 'Alaveteli',
      SKIP_ADMIN_AUTH: false,
      SMTP_MAILER_ADDRESS: 'localhost',
      SMTP_MAILER_AUTHENTICATION: 'plain',
      SMTP_MAILER_DOMAIN: '',
      SMTP_MAILER_ENABLE_STARTTLS_AUTO: true,
      SMTP_MAILER_PASSWORD: '',
      SMTP_MAILER_PORT: 25,
      SMTP_MAILER_USER_NAME: '',
      THEME_BRANCH: false,
      THEME_URL: '',
      THEME_URLS: [],
      TIME_ZONE: 'UTC',
      TURNSTILE_SECRET_KEY: '',
      TURNSTILE_SITE_KEY: '',
      TWITTER_USERNAME: '',
      USE_BULLET_IN_DEVELOPMENT: false,
      USE_DEFAULT_BROWSER_LANGUAGE: true,
      USE_MAILCATCHER_IN_DEVELOPMENT: true,
      USER_SIGN_IN_ACTIVITY_RETENTION_DAYS: 0,
      UTILITY_SEARCH_PATH: ['/usr/bin', '/usr/local/bin'],
      WORKING_OR_CALENDAR_DAYS: 'working'
    }.freeze
    # rubocop:enable Layout/LineLength
  end

  # True for the shipped default or secrets under 64 chars (ProductionSafety).
  def self.default_secret?(value)
    value.to_s.length < 64 || value == DEFAULTS[:SECRET_KEY_BASE]
  end

  def self.get(key, default)
    # Don't use the `Rails.env.test?` as this has to work for external commands
    # when Rails environment isn't loaded.
    value = ENV.fetch("ALAVETELI_#{key}", nil) if ENV['RAILS_ENV'] == 'test'
    value || MySociety::Config.get(key, default)
  end

  def self.method_missing(name)
    key = name.to_s.upcase
    if DEFAULTS.key?(key.to_sym)
      value = get(key, DEFAULTS[key.to_sym])
      case value
      when Hash
        value.with_indifferent_access
      else
        value
      end
    else
      super
    end
  end

  def self.respond_to_missing?(name, include_private = false)
    DEFAULTS.key?(name.to_s.upcase.to_sym) || super
  end

  def self.to_sanitized_hash
    DEFAULTS.keys.each_with_object({}) do |key, memo|
      value = send(key)
      value = '[FILTERED]' if value.present? && key =~ sensitive_key_patterns
      memo[key] = value
    end
  end
end
