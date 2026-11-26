require 'simplecov'
require 'simplecov-lcov'

if ENV['COVERAGE'] == 'local'
  SimpleCov.formatter = SimpleCov::Formatter::HTMLFormatter

else
  SimpleCov::Formatter::LcovFormatter.config do |c|
    c.report_with_single_file = true
    c.single_report_path = 'coverage/lcov.info'
  end

  SimpleCov.formatter = SimpleCov::Formatter::LcovFormatter
end

SimpleCov.start('rails') do
  skip 'vendor/mysociety'
  skip 'lib/has_tag_string'
  skip 'lib/themes'
  skip '.bundle'
end
