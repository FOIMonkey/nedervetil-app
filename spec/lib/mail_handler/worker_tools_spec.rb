require 'spec_helper'
require 'open3'

# Compares script/mail_worker.rb's AlaveteliSandbox stand-in against
# AlaveteliSandbox::Job across fake tool scenarios, since the walk uses the
# error class to tell unpack failures apart from refused/missing tools.
RSpec.describe 'The mail worker’s tools' do
  let(:dir) { Dir.mktmpdir('worker-tools-spec') }

  before do
    File.write(File.join(dir, 'tnef'), <<~SH)
      #!/bin/sh
      case "$1" in
        ok) printf a > a.txt; printf bb > b.txt ;;
        fail) echo broken >&2; exit 1 ;;
        garbled) printf 'bad \\377\\376 bytes\\n' >&2; exit 1 ;;
        many) touch a b c ;;
        big) head -c 100 /dev/zero > big ;;
        link) ln -s /etc/passwd link ;;
        linked) printf a > a.txt; ln -s /etc/passwd link ;;
        slow) sleep 5 ;;
        loud) head -c 2000 /dev/zero ;;
        dir) mkdir d; touch d/f ;;
        huge) head -c 5000 /dev/zero > huge ;;
      esac
    SH
    File.chmod(0o755, File.join(dir, 'tnef'))
    allow(AlaveteliConfiguration).
      to receive(:utility_search_path).and_return([dir])
    allow(Rails.logger).to receive(:warn)
  end

  after { FileUtils.remove_entry(dir) }

  def scenario(behaviour, program: 'tnef', **rest)
    { 'program' => program, 'behaviour' => behaviour }.
      merge(rest.deep_stringify_keys)
  end

  def in_the_worker(scenarios)
    worker(scenarios).fetch('outcomes')
  end

  def worker(scenarios)
    gems = AlaveteliSandbox::MailStep.gem_directories
    environment = %w[RUBYOPT RUBYLIB GEM_HOME GEM_PATH BUNDLE_GEMFILE].
                  to_h { |name| [name, nil] }
    output, errors, status = Open3.capture3(
      environment, RbConfig.ruby, '--disable-gems',
      *gems.flat_map { |gem| ['-I', gem] },
      Rails.root.join('spec/lib/mail_handler/worker_tools_driver.rb').to_s,
      Rails.root.join('script/mail_worker.rb').to_s, dir,
      stdin_data: JSON.generate(scenarios)
    )
    expect(status).to be_success, errors
    JSON.parse(output)
  end

  def in_the_app(scenario)
    limits = scenario.fetch('limits', {}).symbolize_keys
    options = scenario.fetch('options', {}).symbolize_keys
    allow(AlaveteliConfiguration).to receive(:converters_disabled).
      and_return(scenario['disabled'] == true)
    AlaveteliSandbox.job(input: 'input', input_name: 'in.dat',
                         **limits) do |job|
      job.run(scenario['program'], scenario['behaviour'], **options)
      if scenario['read']
        { 'read' => job.read(scenario['read'], max: scenario['max']).bytesize }
      else
        { 'files' => job.files }
      end
    end
  rescue AlaveteliSandbox::Error => e
    { 'error' => e.class.name.demodulize,
      'stderr' => (e.result&.stderr.to_s.strip if e.respond_to?(:result)) }
  end

  scenarios = {
    'a tool that works' =>
      [{ behaviour: 'ok' }, { 'files' => %w[a.txt b.txt] }],
    'a file read back' =>
      [{ behaviour: 'ok', read: 'b.txt', max: 10 }, { 'read' => 2 }],
    'a tool that fails, with what it said' =>
      [{ behaviour: 'fail' }, { 'error' => 'Failed', 'stderr' => 'broken' }],
    'a tool that isn’t installed, with nothing it said' =>
      [{ behaviour: 'ok', program: 'msgconvert' },
       { 'error' => 'Failed', 'stderr' => '' }],
    'a program that isn’t one of the tools' =>
      [{ behaviour: 'ok', program: 'sh' },
       { 'error' => 'Refused', 'stderr' => nil }],
    'any tool while converters are switched off' =>
      [{ behaviour: 'ok', disabled: true },
       { 'error' => 'Refused', 'stderr' => nil }],
    'more files than the job allows' =>
      [{ behaviour: 'many', limits: { output_files: 2 } },
       { 'error' => 'LimitExceeded', 'stderr' => nil }],
    'more bytes than the job allows' =>
      [{ behaviour: 'big', limits: { output_bytes: 10 } },
       { 'error' => 'LimitExceeded', 'stderr' => nil }],
    'a file larger than was asked for' =>
      [{ behaviour: 'ok', read: 'b.txt', max: 1 },
       { 'error' => 'LimitExceeded', 'stderr' => nil }],
    'more output than the step allows' =>
      [{ behaviour: 'loud', options: { stdout: 1000 } },
       { 'error' => 'LimitExceeded', 'stderr' => nil }],
    'a tool that runs out of time' =>
      [{ behaviour: 'slow', options: { timeout: 1 } },
       { 'error' => 'TimedOut', 'stderr' => nil }],
    'a link left in the scratch area' =>
      [{ behaviour: 'link' }, { 'error' => 'Failed', 'stderr' => '' }],
    'a directory left in the scratch area' =>
      [{ behaviour: 'dir' }, { 'error' => 'Failed', 'stderr' => '' }],
    'a link left beside the one file that is read' =>
      [{ behaviour: 'linked', read: 'a.txt', max: 10 },
       { 'error' => 'Failed', 'stderr' => '' }],
    'more files than the job allows, when one is read' =>
      [{ behaviour: 'many', read: 'a', max: 10, limits: { output_files: 2 } },
       { 'error' => 'LimitExceeded', 'stderr' => nil }]
  }

  it 'come to the same in the worker as in the app' do
    asked = scenarios.values.map do |given, _|
      scenario(given[:behaviour], **given.except(:behaviour))
    end
    in_worker = in_the_worker(asked)

    scenarios.each_with_index do |(name, (_, expected)), index|
      expect([name, in_worker[index]]).to eq([name, expected])
      expect([name, in_the_app(asked[index])]).to eq([name, expected])
    end
  end

  it 'report a failure whose tool wrote bytes that are not text' do
    failures = worker([scenario('garbled')]).fetch('failures')
    expect(failures).to eq(
      [{ 'program' => 'tnef', 'reason' => 'tnef failed: bad ?? bytes' }]
    )
  end

  it 'run out of time as usual when the tool ends before it can be ' \
     'killed' do
    slow = scenario('slow', options: { timeout: 1 },
                            ended_before_the_kill: true)
    expect(in_the_worker([slow])).
      to eq([{ 'error' => 'TimedOut', 'stderr' => nil }])
  end

  # The app's limit on a file's size is set by the sandbox, so only the
  # worker's is checked here.
  it 'stop a tool that writes a file over its size limit' do
    outcome, = in_the_worker(
      [scenario('huge', options: { file_size: 1000 })]
    )
    expect(outcome).to include('error' => 'LimitExceeded')
  end
end
