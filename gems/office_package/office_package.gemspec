# frozen_string_literal: true

Gem::Specification.new do |spec|
  spec.name = 'office_package'
  spec.version = '0.1.0'
  spec.authors = ['Nedervetil contributors']
  spec.summary = 'Read, inspect and rewrite Office packages'
  spec.required_ruby_version = '>= 3.4'
  spec.files = Dir.chdir(__dir__) do
    Dir['lib/**/*'].select { |path| File.file?(path) }
  end
  spec.add_dependency 'bigdecimal'
  spec.add_dependency 'nokogiri'
  spec.add_dependency 'rubyzip', '~> 3.7.0'
end
