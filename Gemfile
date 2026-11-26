# Versioning Policy
# =================
#
# In most cases gems should be added with a pessimistic constraint to their
# PATCH level:
#
#    gem 'foo', '~> 1.2.0'
#
# This will install the latest version of the 1.2 series. When 1.3 or 2.0 are
# released, we can assume there may be a breaking change.
#
# If we need to be more specific than this, apply one of the following
# guidelines. Use brief inline comments and commit messages to describe why the
# extra specificity is required. Links to changelogs are very appreciated.
#
# If we need greater than a specific PATCH level, specify that:
#
#    gem 'foo', '~> 1.2.0', '>= 1.2.7'
#
# This will install the latest version of 1.2.x, providing it is 1.2.7 or more.
#
# If there's a version that breaks compatibility (e.g, doesn't support our
# lowest Ruby version) add a compound requirement:
#
#    gem 'foo', '~> 1.2.0', '< 2.0.0'
#
# We tend to keep the rails gem pinned to a specific version for easy reference.
#
# Dependencies of Dependencies
# ============================
#
# Sometimes a gem that we rely on might have a dependency that breaks on update.
# Ideally the problem should be fixed, but failing that, specify a working
# version of the dependency alongside the gem we rely on:
#
#    gem 'foo', '~> 1.2.0'
#      gem 'bar', '< 3.0.0'
#
# Platform Constraints
# ====================
#
# Only use platform constraints that are supported by the lowest version of
# bundler in use, otherwise they won't work. We can't use conditionals like
# `if RUBY_VERSION` because they are specific to the individual developer
# machine.
#
# Gems from GitHub
# ================
#
# Sometimes we need to apply fixes to gems. Generally you'll want to fork the
# code to the mysociety organisation, fix the problem and use that git ref. This
# is a sure-fire way to out of date dependencies, so getting back on the
# upstream release as soon as possible is favourable. Its also better to use
# the ref option rather than branch. For example, if you rebase your bugfix
# branch on upstream/master and force push it, the locked SHA will no longer
# exist on the specified branch. This makes previous versions of Alaveteli
# uninstallable.
#
# Upgrading Gems
# ==============
#
# We use Gemnasium, which alerts us to gem updates.
#
# Most gems will be pessimistically locked at the PATCH level, so you can just
# run `bundle update foo`.
#
#    gem 'foo', '~> 1.2.0'
#
# When a new MINOR or MAJOR release is available, bump the version to the new
# PATCH level and run `bundle update foo`.
#
#    - gem 'foo', '~> 1.2.0'
#    + gem 'foo', '~> 1.3.0'
#
# After running `bundle update foo`, run the specs and read the gem's changelog
# to check for anything that looks like it may impact on our code. All going
# well, the change can be committed. If you find a breakage, either fix our code
# to be compatible with the new version or add a compound requirement less than
# the new version. It is always preferable to upgrade our code.
source 'https://rubygems.org'

# The app's Ruby version. The Dockerfile default, docker-compose's default and
# provisioning pin the same number; change them together.
ruby file: ".ruby-version"

git_source(:mysociety) { |repo| "https://github.com/mysociety/#{repo}.git" }

gem 'rails', '~> 8.1.4', '>= 8.1.4.1'

gem 'pg', '~> 1.7.0'

# Caches load paths and compiled Ruby to speed up boot (config/boot.rb).
gem 'bootsnap', '~> 1.26.2', require: false

gem 'devise', '~> 5.0.4'
gem 'devise-two-factor', '~> 6.4.1'
gem 'activejob-unique', '~> 0.5.0'
gem 'bcrypt', '~> 3.1.22'
gem 'cancancan', '~> 3.7.0'
gem 'charlock_holmes', '~> 0.7.9'
gem 'dalli', '~> 5.3.4'
gem 'exception_notification', '~> 5.0.1'
gem 'friendly_id', '~> 5.7.0'
gem 'htmlentities', '~> 4.4.2'
gem 'icalendar', '~> 2.13.0'
gem 'json', '~> 3.1.0'
gem 'holidays', '~> 11.8.0'
gem 'countries', '~> 8.1.0'
gem 'mail', '~> 2.9.1'
gem 'marcel', '~> 1.2'
gem 'nokogiri', '~> 1.19.7'
gem 'puma', '~> 8.1.2'
gem 'rack', '~> 3.2.9'
gem 'rack-utf8_sanitizer', '~> 1.11.1'
gem 'matrix', '~> 0.4.3'
# Pinned so net/http stays on 0.9.x rather than Ruby 3.4's default 0.6.0.
gem 'net-http', '~> 0.9.1'
gem 'net-protocol', '~> 0.4.0'
gem 'ostruct', '~> 0.6.3'
gem 'redcarpet', '~> 3.6.1'
gem 'rqrcode', '~> 3.2.0'
gem 'rubyzip', '~> 3.7.0'
gem 'ruby-progressbar', '~> 1.13'
gem 'secure_headers', '~> 7.3.0'
gem 'sidekiq', '8.1.7'
gem 'sidekiq-limit_fetch', '~> 4.4.1'
gem 'will_paginate', '~> 4.0.1'
gem 'zip_kit', '~> 6.4.3'

# Keep the patched HTML sanitizing chain when resolving Rails dependencies.
gem 'loofah', '~> 2.25.3'
gem 'rails-html-sanitizer', '~> 1.7.2'

# Gems that are part of Ruby's standard library but need version constraints as
# they are required by other Gem dependencies
gem 'benchmark', '~> 0.5.0'
gem 'csv', '~> 3.3.6'
gem 'drb', '~> 2.2.3'
gem 'pstore', '~> 0.3.0'
gem 'rdoc', '~> 8.1.0'
gem 'uri', '~> 1.1.2'

# Gems related to internationalisation
gem 'i18n', '~> 1.15.2'
gem 'rails-i18n', '~> 8.1.0'
gem 'gettext_i18n_rails', '~> 2.2.0'
  gem 'fast_gettext', '~> 4.2.0'
gem 'gettext', '~> 3.5.2'
gem 'globalize', '~> 7.1.3'
gem 'locale', '~> 2.1.5'

# Assets: Dart Sass builds the stylesheets, Propshaft serves every asset
gem 'dartsass-rails', '~> 0.5.1'
gem 'propshaft', '~> 1.3.2'
gem 'importmap-rails', '~> 2.2.3'
gem 'stimulus-rails', '~> 1.3.4'
gem 'turbo-rails', '~> 2.0.23'

# Feature flags
gem 'alaveteli_features', path: 'gems/alaveteli_features'
gem 'office_package', path: 'gems/office_package'
gem 'pdf_redactor', path: 'gems/pdf_redactor'

# Storage backend (S3 API; also used for S3-compatible stores)
gem 'aws-sdk-s3', require: false

# Storage content analyzers
gem 'excel_analyzer', path: 'gems/excel_analyzer', require: false

group :test do
  gem 'compare-xml', '~> 1.0'
  gem 'webmock', '~> 3.34.0'
  gem 'simplecov', '~> 1.3.2'
  gem 'simplecov-lcov', '~> 0.9.0'
  gem 'capybara', '~> 3.40.0'
  gem 'cuprite', '~> 0.20.0'
end

group :test, :development do
  gem 'brakeman', require: false
  gem 'bullet', '~> 8.3.0'
  gem 'bundler-audit', require: false
  gem 'factory_bot_rails', '~> 6.5.1'
  gem 'rspec-rails', '~> 8.1.0'
  gem 'pry', '~> 0.16.0'
end

group :development do
  gem 'annotaterb', '~> 4.26.0'
  gem 'web-console', '>= 3.3.0'
  gem 'rubocop', '~> 1.92.0', require: false
  gem 'rubocop-capybara', require: false
  gem 'rubocop-factory_bot', require: false
  gem 'rubocop-performance', require: false
  gem 'rubocop-rails', require: false
end
