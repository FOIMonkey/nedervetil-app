# Build theme stylesheets before every suite run (Propshaft raises on missing
# assets). Rebuilt unconditionally because failed Sass leaves an error CSS file
# and deleted partials do not bump file mtimes.
require 'dartsass/runner'

RSpec.configure do |config|
  config.before(:suite) do
    system(*Dartsass::Runner.dartsass_compile_command, exception: true)
  end
end
