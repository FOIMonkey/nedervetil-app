require_relative 'spec_helper'
require 'open3'

RSpec.describe 'office_package in bare Ruby' do
  it 'processes a document without loading the application' do
    path = File.expand_path('../../../spec/fixtures/files/lorem.docx', __dir__)
    paths = %w[nokogiri racc rubyzip bigdecimal].flat_map do |name|
      Gem::Specification.find_by_name(name).full_require_paths
    end
    script = <<~RUBY
      require 'office_package'
      path = ARGV.fetch(0)
      OfficePackage::Guard.check!(path)
      abort 'read failed' unless OfficePackage.read(File.binread(path)).kind == :document
      if defined?(Rails) || defined?(ActiveSupport) || defined?(AlaveteliSandbox)
        abort 'application loaded'
      end
    RUBY
    _, errors, status = Open3.capture3(
      { 'PATH' => ENV.fetch('PATH') }, RbConfig.ruby, '--disable-gems',
      '-I', File.expand_path('../lib', __dir__),
      *paths.flat_map { |dir| ['-I', dir] }, '-e', script, path,
      unsetenv_others: true
    )
    expect(status).to be_success, errors
  end
end
