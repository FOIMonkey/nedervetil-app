require_relative "boot"

require "rails"
require "active_model/railtie"
require "active_job/railtie"
require "active_record/railtie"
require "active_storage/engine"
require "action_controller/railtie"
require "action_mailer/railtie"
require "action_mailbox/engine"
require "action_text/engine"
require "action_view/railtie"

require File.dirname(__FILE__) + '/../lib/configuration'
require File.dirname(__FILE__) + '/../lib/alaveteli_localization'

Bundler.require(*Rails.groups)

module Alaveteli
  # Rails application configuration: Rails 8.1 defaults, autoload paths, SQL
  # schema format, memcache store, Sidekiq jobs, middleware and 404 routing.
  class Application < Rails::Application
    config.load_defaults 8.1

    config.autoload_lib(
      ignore: %w(
        assets
        core_ext
        custom_cops
        has_tag_string
        tasks
        themes
      )
    )

    config.generators.system_tests = nil

    # Preserve PostgreSQL-specific schema features in test database dumps.
    config.active_record.schema_format = :sql

    # nginx supplies X-Forwarded-For; ignore conflicting Client-IP headers to
    # avoid false spoofing errors.
    config.action_dispatch.ip_spoofing_check = false

    # Also controls time-zone-aware model attributes.
    config.time_zone = ::AlaveteliConfiguration.time_zone

    config.cache_store = :mem_cache_store, {
      namespace: "#{AlaveteliConfiguration.domain}_#{RUBY_VERSION}"
    }

    config.active_job.queue_adapter = :sidekiq

    config.after_initialize do |app|
      # Route missing pages through the application, including its privacy gate.
      app.routes.append do
        match '*path', to: 'general#not_found', via: [:get, :post]
      end
    end

    # Avoid setting cookies for empty sessions.
    require "#{Rails.root}/lib/strip_empty_sessions"
    config.middleware.insert_before ::ActionDispatch::Cookies,
                                    StripEmptySessions,
                                    key: '_nedervetil_session',
                                    path: "/",
                                    httponly: true
    Rails.backtrace_cleaner.add_silencer do |line|
      %r{^lib/strip_empty_sessions}.match?(line)
    end

    require "#{Rails.root}/lib/deeply_nested_params"
    config.middleware.insert Rack::Head, DeeplyNestedParams
    Rails.backtrace_cleaner.add_silencer do |line|
      %r{^lib/deeply_nested_params}.match?(line)
    end

    config.middleware.insert 0, Rack::UTF8Sanitizer

    config.action_mailer.default_url_options = {
      host: AlaveteliConfiguration.domain
    }

    config.active_storage.variant_processor = :disabled
  end
end
