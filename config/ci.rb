# Run using bin/ci

CI.run do
  step "Style: RuboCop", "bin/rubocop"
  step "Autoloading: Zeitwerk", "bin/rails zeitwerk:check"
  step "Dead code: partials, Stimulus, methods, routes", "bin/rails dead_code"

  step "Security: Gem audit", "bin/bundler-audit"
  step "Security: Importmap vulnerability audit", "bin/importmap audit"
  step "Security: Brakeman code analysis",
       "bin/brakeman --quiet --no-pager --exit-on-warn --exit-on-error"

  # The full suite isn't run on every bin/ci. Run it with docker/specs
  # (several rspec processes at once, see docker/README.md) once per batch
  # before merging. Add it here when there's a CI server.
  # step "Tests: RSpec", "bin/parallel_specs"
end
