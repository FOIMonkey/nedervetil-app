require 'rubygems'
require 'webmock/rspec'
require "alaveteli_features/spec_helpers"

require_relative 'spec_coverage' if ENV['COVERAGE'] == 'local' || ENV['CI']

ENV["RAILS_ENV"] ||= 'test'
require File.expand_path("../../config/environment", __FILE__)
require 'rspec/rails'

Dir[Rails.root.join("spec/support/**/*.rb")].each { |f| require f }

load "#{Rails.root}/db/seeds.rb"
# Use test-specific translations
locale_path = File.join(File.dirname(__FILE__), 'fixtures', 'locale')
repos = [FastGettext::TranslationRepository.build('app',
                                                   path: locale_path,
                                                   type: :po)]
AlaveteliLocalization.set_default_text_domain('app', repos)

RSpec.configure do |config|
  config.infer_spec_type_from_file_location!

  config.mock_with :rspec do |mocks|
    mocks.verify_partial_doubles = true
  end

  config.include ActiveJob::TestHelper
  config.include ActiveSupport::Testing::TimeHelpers
  config.include Capybara::DSL, type: :request
  config.include ConfigHelper
  config.include LinkToHelper

  config.fixture_paths = [Rails.root.join("spec", "fixtures")]

  # The order (!) of this is important thanks to foreign keys
  config.global_fixtures = :users,
                           :roles,
                           :users_roles,
                           :public_bodies,
                           :public_body_translations,
                           :public_body_versions,
                           :info_requests,
                           :raw_emails,
                           :incoming_messages,
                           :outgoing_messages,
                           :info_request_events,
                           :has_tag_string_tags,
                           :holidays,
                           :public_body_categories,
                           :public_body_category_translations,
                           :public_body_headings,
                           :public_body_heading_translations,
                           :public_body_category_links,
                           :categories,
                           :category_translations,
                           :category_relationships,
                           :notes,
                           :note_translations,
                           'active_storage/blobs',
                           'active_storage/attachments'

  # If you're not using ActiveRecord, or you'd prefer not to run each of your
  # examples within a transaction, remove the following line or assign false
  # instead of true.
  config.use_transactional_fixtures = true

  # If true, the base class of anonymous controllers will be inferred
  # automatically. This will be the default behavior in future versions of
  # rspec-rails.
  config.infer_base_class_for_anonymous_controllers = false

  # Run specs in random order to surface order dependencies. If you find an
  # order dependency and want to debug it, you can fix the order by providing
  # the seed, which is printed after each run.
  #     --seed 1234
  config.order = "random"

  # Clean up storage directories
  config.after(:suite) do
    FileUtils.rm_rf(ActiveStorage::Blob.services.fetch(:test).root)
    FileUtils.rm_rf(ActiveStorage::Blob.services.fetch(:test_fixtures).root)
  end

  # This is a workaround for a strange thing where ActionMailer::Base.deliveries
  # isn't being cleared out correctly in controller specs. So, do it here for
  # everything.
  config.before(:each) do
    ActionMailer::Base.deliveries = []
  end

  config.before(:suite) do
    BCrypt::Engine.cost = 1
    # Unique-job locks outlive a run in Redis and would stop the same jobs
    # being queued in the next one.
    ActiveJob::Uniqueness.unlock!
  end

  # Any test that messes with the locale needs to restore the state afterwards
  # so that it doesn't interfere with any subsequent tests. This is made more
  # complicated by the ApplicationController#set_gettext_locale which sets the
  # locale and so you may be setting the locale in your tests and not even
  # realising it. So, let's make things easier for ourselves and just always
  # restore the locale for all tests.
  config.after(:each) do
    AlaveteliLocalization.set_locales(AlaveteliConfiguration.available_locales,
                                      AlaveteliConfiguration.default_locale)
  end

  config.after(:each) do
    # Reset controller `rate_limit` counters so attempts don't accumulate
    # across examples that share the same test IP and emails.
    ActionController::Base.cache_store.clear
  end
end

include Mail::Matchers

# Helper with_xxx methods for working with feature flags
include AlaveteliFeatures::SpecHelpers

def with_env_tz(new_tz = 'US/Eastern')
  old_tz = ENV.fetch('TZ', nil)
  ENV['TZ'] = new_tz
  yield
ensure
  old_tz ? ENV['TZ'] = old_tz : ENV.delete('TZ')
end

def with_active_record_default_timezone(zone)
  old_zone = ActiveRecord::Base.default_timezone
  ActiveRecord::Base.default_timezone = zone
  yield
ensure
  ActiveRecord::Base.default_timezone = old_zone
end

# Reset the default locale, making sure that the previous default locale
# is also cleared from the fallbacks
def with_default_locale(locale)
  original_default_locale = AlaveteliLocalization.default_locale
  original_fallbacks = I18n.fallbacks
  I18n.fallbacks = nil
  AlaveteliLocalization.set_default_locale(locale)
  yield
ensure
  I18n.fallbacks = original_fallbacks
  AlaveteliLocalization.set_default_locale(original_default_locale)
end

def basic_auth_login(request, username = 'test-basic-user',
                     password = 'test-basic-password')
  request.env["HTTP_AUTHORIZATION"] =
    "Basic " + Base64.encode64("#{username}:#{password}")
end

FactoryBot.definition_file_paths = [Rails.root.join('spec', 'factories')]
FactoryBot.reload

def normalise_whitespace(s)
  s = s.gsub(/\A\s+|\s+\Z/, "")
  s.gsub(/\s+/, " ")
end

RSpec::Matchers.define :be_equal_modulo_whitespace_to do |expected|
  match do |actual|
    normalise_whitespace(actual) == normalise_whitespace(expected)
  end
end
