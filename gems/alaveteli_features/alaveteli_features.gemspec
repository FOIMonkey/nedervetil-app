require 'English'
lib = File.expand_path('../lib', __FILE__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)
require 'alaveteli_features/version'

Gem::Specification.new do |spec|
  spec.name          = "alaveteli_features"
  spec.version       = AlaveteliFeatures::VERSION
  spec.authors       = ["mySociety"]
  spec.email         = ["alaveteli@mysociety.org"]
  spec.description   = "Feature flags for Alaveteli"
  spec.summary       = "Helper methods to manage and test Alaveteli features"
  spec.homepage      = "https://alaveteli.org"
  spec.license       = "MIT"
  spec.required_ruby_version = ">= 3.2.0"

  spec.files = Dir.chdir(__dir__) do
    Dir["lib/**/*", "bin/*", "LICENSE*", "README*", "Rakefile"].
      select { |f| File.file?(f) }
  end
  spec.executables   = spec.files.grep(%r{^bin/}) { |f| File.basename(f) }
  spec.require_paths = ["lib"]

  spec.add_dependency "rails", ">= 8.0.1", "< 8.2.0"
  spec.add_dependency "flipper", "~> 1.3.2"
  spec.add_dependency "flipper-active_record", "~> 1.3.2"

  spec.add_development_dependency "rake", "~> 13.1"
  spec.add_development_dependency "rspec", "~> 3.7"
  spec.add_development_dependency "rspec-rails", "~> 8.0"
end
