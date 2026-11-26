# frozen_string_literal: true

# Subprocess driver for worker_tools_spec.rb (run with --disable-gems).
# Loads the mail worker with a fake BIN dir and runs JSON scenarios from stdin.
require 'json'

worker, bin = ARGV
load worker
AlaveteliSandbox::ToolJob.send(:remove_const, :BIN)
AlaveteliSandbox::ToolJob.const_set(:BIN, bin)

outcomes = JSON.parse($stdin.read).map do |scenario|
  limits = scenario.fetch('limits', {}).transform_keys(&:to_sym)
  options = scenario.fetch('options', {}).transform_keys(&:to_sym)
  AlaveteliSandbox.disabled = scenario['disabled'] == true
  if scenario['ended_before_the_kill']
    # The tool ends just as its time runs out: nothing is left to kill.
    Process.define_singleton_method(:kill) { |*| raise Errno::ESRCH }
  end
  AlaveteliSandbox.job(input: 'input', input_name: 'in.dat', **limits) do |job|
    job.run(scenario.fetch('program'), scenario.fetch('behaviour'), **options)
    if scenario['read']
      { 'read' => job.read(scenario['read'], max: scenario['max']).bytesize }
    else
      { 'files' => job.files }
    end
  end
rescue AlaveteliSandbox::Error => e
  said = e.result&.stderr.to_s.dup if e.respond_to?(:result)
  { 'error' => e.class.name.split('::').last,
    'stderr' => said&.force_encoding('UTF-8')&.scrub('?')&.strip }
end
puts JSON.generate('outcomes' => outcomes,
                   'failures' => AlaveteliSandbox.failures)
