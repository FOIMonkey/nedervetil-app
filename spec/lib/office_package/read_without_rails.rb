# frozen_string_literal: true

# Subprocess driver for readers_without_rails_spec.rb (run with --disable-gems).
# Reads files in ARGV[0] without Rails and prints results + loaded features.
require 'json'
# Nokogiri needs Gem::Version and Gem::Platform.local on require.
require 'rubygems'
require 'office_package/guard'
require 'office_package/inspector'
require 'office_package/sheets'
require_relative '../../support/office_reader_description'

max_rows, max_columns = ARGV.values_at(1, 2).map { |limit| Integer(limit) }
files = Dir[File.join(ARGV.fetch(0), '*')].to_h do |path|
  [File.basename(path),
   OfficeReaderDescription.of(path, max_rows: max_rows,
                                    max_columns: max_columns)]
end

puts JSON.generate(
  files: files,
  limits: OfficePackage.limits,
  loaded: $LOADED_FEATURES,
  rails: %w[Rails ActiveSupport ActiveRecord Bundler AlaveteliSandbox].
    select { |name| Object.const_defined?(name) }
)
