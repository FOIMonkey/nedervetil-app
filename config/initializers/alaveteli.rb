# Helpers from commonlib; see vendor/mysociety/README.
$LOAD_PATH.push(File.expand_path('../../vendor/mysociety/rblib', __dir__))

load "validate.rb"
load "config.rb"
load "format.rb"
load "debug_helpers.rb"
load "util.rb"

ALAVETELI_VERSION = '0.46.5.0'.freeze

# Load monkey patches and other things from lib/
require 'core_ext/warning'
require 'core_ext/active_storage_ensure_attached'
require 'core_ext/action_text_without_attachments'
require 'core_ext/active_record_materialized_cte'

require 'use_spans_for_errors.rb'
require 'world_foi_websites.rb'
require 'alaveteli_external_command.rb'
require 'fetch_url.rb'
require 'attachment_to_text'
require 'health_checks'
require 'mail_handler'
require 'normalize_string'
require 'alaveteli_file_types'
require 'theme'
require 'date_quarter'
require 'public_body_csv'
require 'alaveteli_text_masker'
require 'database_collation'
require 'default_late_calculator'
require 'analytics_event'
require 'alaveteli_gettext/fuzzy_cleaner'
require 'alaveteli_spam_term_checker'
require 'user_stats'
require 'alaveteli_mail_poller'
require 'safe_redirect'

# Allow tests to be run under a non-superuser database account if required
if Rails.env.test?
  test_config = ActiveRecord::Base.configurations.find_db_config(:test).
    configuration_hash
  require 'no_constraint_disabling' unless test_config['constraint_disabling']
end
