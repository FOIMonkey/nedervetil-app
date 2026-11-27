# frozen_string_literal: true

lib = File.expand_path('lib', __dir__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)

Gem::Specification.new do |spec|
  spec.name = "excel_analyzer"
  spec.version = "0.0.1"
  spec.authors = ["mySociety"]
  spec.email = ["alaveteli@mysociety.org"]

  spec.summary = "File analysers for ActiveStorage"
  spec.description = "Extra ActiveStorage Analysers for Alaveteli"
  spec.homepage = "https://alaveteli.org"
  spec.license = "AGPL-3.0-or-later"
  spec.required_ruby_version = ">= 3.2.0"

  spec.metadata["homepage_uri"] = spec.homepage

  spec.files = Dir.chdir(__dir__) do
    Dir["lib/**/*", "LICENSE*", "README*"].select { |f| File.file?(f) }
  end
  spec.require_paths = ["lib"]

  spec.add_dependency "activestorage"
  spec.add_dependency "nokogiri"
  spec.add_dependency "rubyzip"
  spec.add_dependency "mail"
  spec.add_dependency "marcel"

  spec.add_development_dependency "bundler"
  spec.add_development_dependency "pry"
  spec.add_development_dependency "rake"
  spec.add_development_dependency "rspec"
end
