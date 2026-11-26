require 'spec_helper'
require 'external_command'

RSpec.describe ExternalCommand do
  def run(*args)
    described_class.new(*args).run
  end

  it 'captures standard output and the exit status' do
    command = run('echo', 'hello')
    expect(command.out).to eq("hello\n")
    expect(command.exited).to be true
    expect(command.status).to eq 0
    expect(command.timed_out).to be_nil
  end

  it 'captures standard error and a non-zero exit status' do
    command = run('sh', '-c', 'echo oops >&2; exit 3')
    expect(command.err).to eq("oops\n")
    expect(command.exited).to be true
    expect(command.status).to eq 3
  end

  it 'reports a process killed by a signal as not exited' do
    command = run('sh', '-c', 'kill -SEGV $$')
    expect(command.exited).to be false
    expect(command.status).to be_nil
    expect(command.timed_out).to be_nil
  end

  it 'passes stdin_string to the process, binary bytes intact' do
    input = (Array(0..255).pack('C*') * 512).b
    command = run('cat', stdin_string: input)
    expect(command.out).to eq input
  end

  it 'passes long text with non-ASCII characters to the process intact' do
    # Far more than a pipe holds, so it is written in several pieces
    input = 'café ' * 100_000
    command = run('cat', stdin_string: input)
    expect(command.out.bytesize).to eq input.bytesize
    expect(command.out.b).to eq input.b
  end

  it 'closes standard input when there is no stdin_string' do
    command = run('cat')
    expect(command.out).to eq ''
    expect(command.status).to eq 0
  end

  it 'returns bytes that are not valid text as binary by default' do
    command = run('printf', '\377\376')
    expect(command.out.encoding).to eq Encoding::ASCII_8BIT
    expect(command.out).to eq "\xFF\xFE".b
  end

  it 'returns text in the default external encoding when asked' do
    command = run('printf', 'caf\303\251', binary_output: false)
    expect(command.out.encoding).to eq Encoding.default_external
    expect(command.out).to eq 'café'.encode(Encoding.default_external)
  end

  it 'appends to the strings it is given' do
    out = +'before '
    err = +'before '
    run('sh', '-c', 'echo out; echo err >&2',
        append_to: out, append_errors_to: err)
    expect(out).to eq "before out\n"
    expect(err).to eq "before err\n"
  end

  describe 'env' do
    let(:name) { 'EXTERNAL_COMMAND_SPEC_VALUE' }

    around do |example|
      saved = ENV.fetch(name, nil)
      example.run
    ensure
      ENV[name] = saved
    end

    it 'sets variables for the process only' do
      ENV.delete(name)
      command = run('sh', '-c', "printf %s \"$#{name}\"",
                    env: { name => 'child' })
      expect(command.out).to eq 'child'
      expect(ENV).not_to have_key(name)
    end

    it 'leaves this process untouched when the process times out' do
      ENV.delete(name)
      command = run('sleep', '10', env: { name => 'child' }, timeout: 0.5)
      expect(command.timed_out).to be true
      expect(ENV).not_to have_key(name)
    end

    it 'unsets a variable given as nil, for the process only' do
      ENV[name] = 'parent'
      command = run('sh', '-c', "printf %s \"${#{name}-unset}\"",
                    env: { name => nil })
      expect(command.out).to eq 'unset'
      expect(ENV.fetch(name, nil)).to eq 'parent'
    end
  end

  describe 'timeout' do
    it 'stops a process that runs too long' do
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      command = run('sleep', '10', timeout: 0.5)
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

      expect(command.timed_out).to be true
      expect(command.exited).to be false
      expect(command.status).to be_nil
      expect(elapsed).to be < 5
    end

    it 'keeps output written before the timeout' do
      command = run('sh', '-c', 'echo early; exec sleep 10', timeout: 1)
      expect(command.timed_out).to be true
      expect(command.out).to eq "early\n"
    end

    it 'kills a process that ignores TERM' do
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      command = run('sh', '-c', 'trap "" TERM; exec sleep 10', timeout: 0.5)
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

      expect(command.timed_out).to be true
      expect(command.exited).to be false
      expect(elapsed).to be < 5
    end

    it 'raises rather than waits when the process cannot be stopped' do
      children = []
      allow(Open3).to receive(:popen3).and_wrap_original do |popen3, *args|
        popen3.call(*args).tap { |streams| children << streams.last }
      end
      allow_any_instance_of(described_class).
        to receive(:try_to_kill).and_return(false)

      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      expect { run('sleep', '10', timeout: 0.5) }.
        to raise_error(described_class::ChildUnterminated)
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
      expect(elapsed).to be < 3
    ensure
      children.each do |child|
        Process.kill('KILL', child.pid)
      rescue Errno::ESRCH
        nil
      end
    end

    it 'leaves a process that finishes in time alone' do
      command = run('echo', 'quick', timeout: 10)
      expect(command.timed_out).to be_nil
      expect(command.exited).to be true
      expect(command.out).to eq "quick\n"
    end
  end

  describe 'memory_limit',
           if: RUBY_PLATFORM.include?('linux') do
    it 'limits the address space of the process, not this one' do
      before = Process.getrlimit(Process::RLIMIT_AS)
      limit = 512 * 1024 * 1024
      command = run('sh', '-c', 'ulimit -v', memory_limit: limit)

      expect(command.out.strip).to eq((limit / 1024).to_s)
      expect(Process.getrlimit(Process::RLIMIT_AS)).to eq before
    end
  end
end
