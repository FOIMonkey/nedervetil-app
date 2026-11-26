require 'spec_helper'

RSpec.describe AlaveteliSandbox do
  def configure(**values)
    values.each do |key, value|
      allow(AlaveteliConfiguration).to receive(key).and_return(value)
    end
  end

  before { allow(Rails.logger).to receive(:warn) }

  describe '.mode' do
    it 'is off by default' do
      expect(described_class.mode).to eq(:off)
    end

    it 'reads required, ignoring case and spaces' do
      configure(sandbox_converters: ' Required ')
      expect(described_class.mode).to eq(:required)
    end

    it 'is invalid for anything else' do
      configure(sandbox_converters: 'yes')
      expect(described_class.mode).to eq(:invalid)
    end
  end

  describe '.check_configuration!' do
    it 'accepts the defaults' do
      expect { described_class.check_configuration! }.not_to raise_error
    end

    it 'refuses an invalid mode' do
      configure(sandbox_converters: 'on')
      expect { described_class.check_configuration! }.
        to raise_error(AlaveteliSandbox::ConfigurationError, /must be one of/)
    end

    it 'accepts all three converter cells with the sandbox required' do
      configure(sandbox_converters: 'required', sandbox_pdf_cell: '/run/p',
                sandbox_office_cell: '/run/o', sandbox_mail_cell: '/run/m')
      expect { described_class.check_configuration! }.not_to raise_error
    end

    it 'refuses some converter cells without the rest' do
      configure(sandbox_converters: 'required', sandbox_pdf_cell: '/run/p',
                sandbox_office_cell: '/run/o')
      expect { described_class.check_configuration! }.
        to raise_error(AlaveteliSandbox::ConfigurationError,
                       /must all be set, or none/)
    end

    it 'refuses converter cells without the sandbox required' do
      configure(sandbox_pdf_cell: '/run/p', sandbox_office_cell: '/run/o',
                sandbox_mail_cell: '/run/m')
      expect { described_class.check_configuration! }.
        to raise_error(AlaveteliSandbox::ConfigurationError,
                       /need SANDBOX_CONVERTERS: required/)
    end
  end

  describe '.cell_for' do
    it 'names the cell that runs each program' do
      expect(described_class.cell_for('pdftotext')).to eq('pdf')
      expect(described_class.cell_for('magick')).to eq('pdf')
      expect(described_class.cell_for('soffice')).to eq('office')
      expect(described_class.cell_for('libreoffice')).to eq('office')
      expect(described_class.cell_for('tnef')).to eq('mail')
      expect(described_class.cell_for('sh')).to be_nil
    end

    it 'has a socket setting for every cell that runs programs' do
      expect(AlaveteliSandbox::Cell.sockets.keys).
        to eq(described_class::CELL_PROGRAMS.keys)
    end

    it 'gives every program to one cell' do
      programs = described_class::CELL_PROGRAMS.values.flatten
      expect(programs).to eq(programs.uniq)
      expect(described_class::PROGRAMS).to match_array(programs)
    end
  end

  describe '.volume_problem' do
    let(:volume) { Dir.mktmpdir('sandbox-volume') }
    let(:options) { %w[rw nosuid nodev noexec relatime] }

    before do
      File.chmod(0o700, volume)
      configure(sandbox_volume: volume)
    end

    after { FileUtils.remove_entry(volume) }

    def mounted(type: 'tmpfs', options: self.options)
      allow(described_class).to receive(:mounts).
        and_return([{ point: volume, type: type, options: options }])
    end

    it 'is nil for a private tmpfs' do
      mounted
      expect(described_class.volume_problem).to be_nil
    end

    it 'reports a missing mount' do
      allow(described_class).to receive(:mounts).and_return([])
      expect(described_class.volume_problem).to match(/is not mounted/)
    end

    it 'reports another filesystem type' do
      mounted(type: 'ext4')
      expect(described_class.volume_problem).to match(/ext4, not tmpfs/)
    end

    it 'reports missing mount options' do
      mounted(options: %w[rw nosuid])
      expect(described_class.volume_problem).
        to match(/without nodev, noexec/)
    end

    it 'reports a volume others can read' do
      mounted
      File.chmod(0o755, volume)
      expect(described_class.volume_problem).to match(/must be private/)
    end

    context 'with converter cells' do
      before do
        configure(sandbox_converters: 'required', sandbox_pdf_cell: '/run/p',
                  sandbox_office_cell: '/run/o', sandbox_mail_cell: '/run/m')
        mounted
      end

      it 'is nil for a volume its group can enter and nobody else can' do
        File.chmod(0o710, volume)
        expect(described_class.volume_problem).to be_nil
      end

      it 'reports a volume the cells can’t enter' do
        expect(described_class.volume_problem).to match(/must be mode 710/)
      end

      it 'reports a volume that is any looser' do
        [0o750, 0o770, 0o711, 0o715, 0o2710, 0o1710].each do |mode|
          File.chmod(mode, volume)
          expect(described_class.volume_problem).to match(/must be mode 710/)
        end
      end

      it 'reports a group this user isn’t in' do
        File.chmod(0o710, volume)
        allow(Process).to receive_messages(groups: [], egid: -1)
        expect(described_class.volume_problem).
          to match(/group isn't one of this user's/)
      end
    end

    it 'unescapes spaces in mountinfo paths' do
      expect(described_class.unescape_mount_path('/run/a\\040b')).
        to eq('/run/a b')
    end
  end

  describe '.program_path' do
    it 'finds a program on the utility search path' do
      expect(described_class.program_path('sh', sandboxed: false)).
        to match(%r{/sh\z})
    end

    it 'fails for a missing program' do
      expect { described_class.program_path('nope', sandboxed: false) }.
        to raise_error(AlaveteliSandbox::Failed, /not installed/)
    end

    it 'refuses a program outside /usr when sandboxed' do
      dir = Dir.mktmpdir
      program = File.join(dir, 'pdftotext')
      File.write(program, "#!/bin/sh\n")
      File.chmod(0o755, program)
      configure(utility_search_path: [dir])

      expect { described_class.program_path('pdftotext', sandboxed: true) }.
        to raise_error(AlaveteliSandbox::Refused, %r{outside /usr})
    ensure
      FileUtils.remove_entry(dir)
    end
  end

  describe '.self_test' do
    it 'runs true directly when off' do
      expect(described_class.self_test).to be_success
    end
  end

  describe '.context' do
    it 'names the process outside requests and jobs' do
      expect(described_class.context).to start_with('process=')
    end

    it 'names the job inside a job' do
      job = instance_double(ApplicationJob, job_id: 'abc')
      allow(job).to receive(:class).and_return(FoiAttachment::MaskJob)
      ActiveSupport::ExecutionContext.set(job: job) do
        expect(described_class.context).
          to eq('job=FoiAttachment::MaskJob job_id=abc')
      end
    end

    it 'names the page and a job it ran inline' do
      controller = double(request: double(path: '/request/a_request'))
      job = instance_double(ApplicationJob, job_id: 'abc')
      allow(job).to receive(:class).and_return(FoiAttachment::MaskJob)
      ActiveSupport::ExecutionContext.set(controller: controller, job: job) do
        expect(described_class.context).to eq(
          'request=/request/a_request job=FoiAttachment::MaskJob job_id=abc'
        )
      end
    end
  end
end

RSpec.describe AlaveteliSandbox::Job do
  before { allow(Rails.logger).to receive(:warn) }

  def allow_shell
    programs = AlaveteliSandbox::PROGRAMS + %w[sh]
    stub_const('AlaveteliSandbox::PROGRAMS', programs)
  end

  describe 'input' do
    it 'writes bytes as a read-only input file' do
      AlaveteliSandbox.job(input: 'hello', input_name: 'a.txt') do |job|
        expect(File.binread(job.input)).to eq('hello')
        expect(File.stat(job.input).mode & 0o777).to eq(0o400)
      end
    end

    it 'copies a Pathname input' do
      Tempfile.create('source') do |source|
        source.write('from a file')
        source.flush
        AlaveteliSandbox.job(input: Pathname(source.path)) do |job|
          expect(File.read(job.input)).to eq('from a file')
        end
      end
    end

    it 'copies an IO input' do
      AlaveteliSandbox.job(input: StringIO.new('streamed')) do |job|
        expect(File.read(job.input)).to eq('streamed')
      end
    end

    it 'refuses unsafe names' do
      expect {
        AlaveteliSandbox.job(input: 'x', input_name: '../evil') { nil }
      }.to raise_error(ArgumentError, /unsafe/)
    end

    it 'refuses the job when the volume is full' do
      allow(File).to receive(:open).and_call_original
      allow(File).to receive(:open).
        with(a_string_ending_with('/in/input'), any_args).
        and_raise(Errno::ENOSPC)
      expect(Rails.logger).to receive(:warn).with(/volume_full/)
      expect { AlaveteliSandbox.job(input: 'x') { nil } }.
        to raise_error(AlaveteliSandbox::Refused, /No space left/)
    end

    it 'still raises a missing input file as it is' do
      expect {
        AlaveteliSandbox.job(input: Pathname('/nonexistent/x')) { nil }
      }.to raise_error(Errno::ENOENT)
    end
  end

  it 'removes the job directory afterwards, even when the block raises' do
    dir = nil
    expect do
      AlaveteliSandbox.job(input: 'x') do |job|
        dir = File.dirname(File.dirname(job.input))
        raise 'boom'
      end
    end.to raise_error('boom')
    expect(File.exist?(dir)).to be false
  end

  describe '#run' do
    before { allow_shell }

    it 'returns the output of a successful step' do
      result = AlaveteliSandbox.job do |job|
        job.run('sh', '-c', 'printf converted')
      end
      expect(result.stdout).to eq('converted')
    end

    it 'runs in the scratch area, where later steps find earlier outputs' do
      AlaveteliSandbox.job do |job|
        job.run('sh', '-c', 'printf one > first.txt')
        job.run('sh', '-c', 'cat first.txt > second.txt')
        expect(job.files).to eq(%w[first.txt second.txt])
        expect(job.read('second.txt', max: 10)).to eq('one')
      end
    end

    it 'inherits the environment when off, as AlaveteliExternalCommand did' do
      ENV['SANDBOX_SPEC_INHERITED'] = 'yes'
      env = AlaveteliSandbox.job do |job|
        job.run('sh', '-c', 'env', env: { 'SANDBOX_SPEC_ADDED' => 'too' }).
          stdout
      end
      expect(env).to include('SANDBOX_SPEC_INHERITED=yes')
      expect(env).to include('SANDBOX_SPEC_ADDED=too')
    ensure
      ENV.delete('SANDBOX_SPEC_INHERITED')
    end

    it 'refuses programs that are not allowed' do
      expect { AlaveteliSandbox.job { |job| job.run('true') } }.
        to raise_error(AlaveteliSandbox::Refused, /not_allowed/)
    end

    it 'refuses Ghostscript' do
      expect { AlaveteliSandbox.job { |job| job.run('gs', '--version') } }.
        to raise_error(AlaveteliSandbox::Refused, /not_allowed/)
    end

    it 'refuses everything when converters are disabled' do
      allow(AlaveteliConfiguration).
        to receive(:converters_disabled).and_return(true)
      expect(Rails.logger).to receive(:warn).with(/\[sandbox\] disabled/)
      expect { AlaveteliSandbox.job { |job| job.run('sh', '-c', 'true') } }.
        to raise_error(AlaveteliSandbox::Refused, /disabled/)
    end

    it 'refuses to run the mail worker outside the sandbox' do
      allow(Rails.logger).to receive(:warn)
      expect(AlaveteliSandbox::ProcessRunner).not_to receive(:new)

      expect do
        AlaveteliSandbox.job do |job|
          job.run_mail_read(bodies: 'all', stored: false)
        end
      end.to raise_error(AlaveteliSandbox::Refused, /sandbox_required/)
    end

    it 'refuses to run the Office worker outside the sandbox' do
      allow(Rails.logger).to receive(:warn)
      expect(AlaveteliSandbox::ProcessRunner).not_to receive(:new)

      expect do
        AlaveteliSandbox.job do |job|
          job.run_office_read(sections: %w[guard])
        end
      end.to raise_error(AlaveteliSandbox::Refused, /sandbox_required/)
    end

    it 'raises Failed with the result when the program fails' do
      expect do
        AlaveteliSandbox.job do |job|
          job.run('sh', '-c', 'echo bad >&2; exit 3')
        end
      end.to raise_error(AlaveteliSandbox::Failed, /exit 3/) { |error|
        expect(error.result.stderr).to eq("bad\n")
      }
    end

    it 'kills the whole process group on timeout' do
      marker = File.join(Dir.tmpdir, "sandbox-spec-#{SecureRandom.hex(4)}")
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      expect do
        AlaveteliSandbox.job do |job|
          job.run('sh', '-c', "(sleep 3; touch #{marker}) & sleep 30",
                  timeout: 1)
        end
      end.to raise_error(AlaveteliSandbox::TimedOut)
      took = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
      expect(took).to be < 6
      sleep 3
      expect(File.exist?(marker)).to be false
    ensure
      FileUtils.rm_f(marker)
    end

    it 'times out a program that closes its output but keeps running' do
      expect do
        AlaveteliSandbox.job do |job|
          job.run('sh', '-c', 'exec >/dev/null 2>&1; sleep 30', timeout: 1)
        end
      end.to raise_error(AlaveteliSandbox::TimedOut)
    end

    it 'kills a step whose stdout passes its cap' do
      expect do
        AlaveteliSandbox.job do |job|
          job.run('sh', '-c', 'while :; do echo flood; done', stdout: 1000)
        end
      end.to raise_error(AlaveteliSandbox::LimitExceeded, /too much output/)
    end

    it 'reports a step killed for writing too large a file as a limit' do
      expect do
        AlaveteliSandbox.job { |job| job.run('sh', '-c', 'kill -XFSZ $$') }
      end.to raise_error(AlaveteliSandbox::LimitExceeded, /size limit/)
    end

    it 'reports a shell-style 128 + XFSZ exit status as a limit' do
      status = 128 + Signal.list['XFSZ']
      expect do
        AlaveteliSandbox.job { |job| job.run('sh', '-c', "exit #{status}") }
      end.to raise_error(AlaveteliSandbox::LimitExceeded, /size limit/)
    end

    it 'keeps only the capped part of stderr' do
      result = AlaveteliSandbox.job do |job|
        job.run('sh', '-c', 'head -c 5000 /dev/zero >&2; printf ok',
                stderr: 100)
      end
      expect(result.stderr.bytesize).to eq(100)
      expect(result.stdout).to eq('ok')
    end
  end

  describe 'checking the scratch area after each step' do
    before { allow_shell }

    def step(script)
      AlaveteliSandbox.job { |job| job.run('sh', '-c', script) }
    end

    it 'fails a step that leaves a symbolic link' do
      expect(Rails.logger).to receive(:warn).with(/unexpected_output/)
      expect { step('ln -s /etc/passwd link') }.
        to raise_error(AlaveteliSandbox::Failed, /unexpected link \(link\)/)
    end

    it 'fails a step that leaves a symbolic link deeper down' do
      expect { step('mkdir -p a/b && ln -s /etc a/b/etc') }.
        to raise_error(AlaveteliSandbox::Failed,
                       %r{unexpected link \(a/b/etc\)})
    end

    it 'fails a step that leaves a hard link' do
      expect { step('printf x > a; ln a b') }.
        to raise_error(AlaveteliSandbox::Failed, /unexpected file/)
    end

    it 'fails a step that leaves a named pipe' do
      expect { step('mkfifo pipe') }.
        to raise_error(AlaveteliSandbox::Failed, /unexpected fifo/)
    end

    it 'caps the number of files and directories, nested ones included' do
      expect do
        AlaveteliSandbox.job(output_files: 3) do |job|
          job.run('sh', '-c',
                  'mkdir -p a/b; for i in 1 2 3; do printf x > a/b/f$i; done')
        end
      end.to raise_error(AlaveteliSandbox::LimitExceeded, /number of files/)
    end

    it 'caps the bytes written, nested files included' do
      expect do
        AlaveteliSandbox.job(output_bytes: 10) do |job|
          job.run('sh', '-c',
                  'mkdir d; printf 012345 > d/a; printf 012345 > d/b')
        end
      end.to raise_error(AlaveteliSandbox::LimitExceeded, /amount of output/)
    end

    it 'allows directories and plain files' do
      expect { step('mkdir -p out/pages && printf x > out/pages/1.png') }.
        not_to raise_error
    end
  end

  describe 'outputs' do
    before { allow_shell }

    it 'lists only regular files at the top of the scratch area' do
      AlaveteliSandbox.job do |job|
        job.run('sh', '-c', 'mkdir subdir')
        expect { job.files }.
          to raise_error(AlaveteliSandbox::Failed, /unexpected output/)
      end
    end

    it 'keeps the names programs chose, spaces and all' do
      AlaveteliSandbox.job do |job|
        job.run('sh', '-c', 'printf x > "Report 2024 – final.docx"')
        expect(job.files).to eq(['Report 2024 – final.docx'])
        expect(job.read('Report 2024 – final.docx', max: 10)).to eq('x')
      end
    end

    it 'reads nested outputs without following a link anywhere on the path' do
      AlaveteliSandbox.job do |job|
        job.run('sh', '-c', 'mkdir -p d/e && printf ok > d/e/out')
        path = File.join(job.scratch, 'd', 'e', 'out')
        expect(job.read_file(path, max: 10)).to eq('ok')

        File.rename(File.join(job.scratch, 'd'),
                    File.join(job.scratch, 'moved'))
        File.symlink(File.join(job.scratch, 'moved'),
                     File.join(job.scratch, 'd'))
        expect { job.read_file(path, max: 10) }.
          to raise_error(AlaveteliSandbox::Failed, /symbolic link/)

        moved = File.join(job.scratch, 'moved', 'e', 'out')
        File.delete(moved)
        File.symlink('/etc/hostname', moved)
        expect { job.read_file(moved, max: 100) }.
          to raise_error(AlaveteliSandbox::Failed, /symbolic link/)
      end
    end

    it 'refuses to read paths outside the job' do
      AlaveteliSandbox.job do |job|
        expect { job.read_file('/etc/hostname', max: 100) }.
          to raise_error(ArgumentError, /not in this job/)
        expect { job.read_file("#{job.scratch}/../in/../../x", max: 100) }.
          to raise_error(ArgumentError, /not in this job/)
      end
    end

    it 'cannot be tricked by a detached process that swaps an output later' do
      AlaveteliSandbox.job do |job|
        job.run('sh', '-c', 'printf ok > out; ' \
                            'setsid sh -c "exec </dev/null >/dev/null 2>&1; ' \
                            'sleep 1; rm -f out; ln -s /etc/hostname out" &')
        expect(job.read('out', max: 10)).to eq('ok')
        sleep 2
        expect { job.read('out', max: 100) }.
          to raise_error(AlaveteliSandbox::Failed, /symbolic link/)
      end
    end

    it 'refuses output names that are paths' do
      AlaveteliSandbox.job do |job|
        expect { job.read('../in/input', max: 10) }.
          to raise_error(ArgumentError, /unsafe output name/)
      end
    end

    # Ruby preallocates IO#read(n), so never pass an untrusted max directly.
    it 'asks no more of a read than the file holds, whatever is allowed' do
      asked = []
      allow_any_instance_of(File).
        to receive(:read).and_wrap_original do |original, *length|
          asked << length
          original.call(*length)
        end

      AlaveteliSandbox.job do |job|
        job.run('sh', '-c', 'printf 0123456789 > out.txt; : > empty')
        expect(job.read('out.txt', max: 1 << 30)).to eq('0123456789')
        expect(job.read('empty', max: 1 << 30)).to eq('')
      end

      expect(asked).to eq([[11], [1]])
    end

    it 'enforces read and copy limits' do
      AlaveteliSandbox.job do |job|
        job.run('sh', '-c', 'printf 0123456789 > out.txt')
        expect { job.read('out.txt', max: 5) }.
          to raise_error(AlaveteliSandbox::LimitExceeded)
        expect(job.read('out.txt', max: 10)).to eq('0123456789')

        expect(job.copy_out('out.txt', to: StringIO.new, max: 10)).to eq(10)
        expect { job.copy_out('out.txt', to: StringIO.new, max: 3) }.
          to raise_error(AlaveteliSandbox::LimitExceeded)
      end
    end

    it 'stops the step itself at the output caps (before anything is listed)' do
      AlaveteliSandbox.job(output_files: 3) do |job|
        expect do
          job.run('sh', '-c', 'for i in 1 2 3 4; do printf x > f$i; done')
        end.to raise_error(AlaveteliSandbox::LimitExceeded, /number of files/)
      end
    end

    it 'filters by pattern' do
      AlaveteliSandbox.job do |job|
        job.run('sh', '-c', 'printf x > page-1.png; printf x > page-2.png; ' \
                            'printf x > notes')
        expect(job.files(/\Apage-\d+\.png\z/)).
          to eq(%w[page-1.png page-2.png])
      end
    end
  end

  describe 'when sandboxed' do
    let(:volume) { Dir.mktmpdir('sandbox-volume') }
    let(:bwrap) { File.join(Dir.tmpdir, "fake-bwrap-#{SecureRandom.hex(4)}") }

    before do
      allow(AlaveteliConfiguration).
        to receive(:sandbox_converters).and_return('required')
      allow(AlaveteliConfiguration).
        to receive(:sandbox_volume).and_return(volume)
      allow(AlaveteliConfiguration).to receive(:sandbox_bwrap).and_return(bwrap)
      allow(AlaveteliSandbox).to receive(:volume_problem).and_return(nil)
      # These stand-ins make no PID namespace to confirm.
      allow(AlaveteliSandbox::ProcessRunner).
        to receive(:confirm_namespace?).and_return(false)
    end

    after do
      FileUtils.remove_entry(volume)
      FileUtils.rm_f(bwrap)
    end

    def fake_bwrap(script)
      File.write(bwrap, "#!/bin/sh\n#{script}\n")
      File.chmod(0o755, bwrap)
    end

    it 'refuses to start when the volume is not ready' do
      allow(AlaveteliSandbox).
        to receive(:volume_problem).and_return('/run/x is not mounted')
      expect(Rails.logger).to receive(:warn).with(/volume_not_mounted/)
      expect { AlaveteliSandbox.job { nil } }.
        to raise_error(AlaveteliSandbox::Refused, /not mounted/)
    end

    it 'keeps jobs on the volume, in private directories' do
      AlaveteliSandbox.job(input: 'x') do |job|
        job_dir = File.dirname(File.dirname(job.input))
        expect(File.dirname(job_dir)).to eq(volume)
        expect(job.input).to eq(File.join(job_dir, 'in', 'input'))
        expect(job.scratch('out.txt')).
          to eq(File.join(job_dir, 'scratch', 'out.txt'))
        expect(File.stat(job_dir).mode & 0o777).to eq(0o700)
      end
    end

    it 'keeps no LibreOffice profile inside the shared scratch directory' do
      AlaveteliSandbox.job do |job|
        expect(Dir.children(job.scratch)).to eq([])
        expect(job.files).to eq([])
      end
    end

    it 'runs the step through bubblewrap, binding the job at its paths' do
      fake_bwrap('echo "{\"child-pid\": 2}" >&3; printf "%s\n" "$@"')
      AlaveteliSandbox.job do |job|
        args = job.run('pdftotext', job.input, '-').stdout.lines(chomp: true)
        expect(args).to include('--unshare-all', '--unshare-user',
                                '--disable-userns', '--clearenv',
                                '/usr/bin/prlimit')
        expect(args.each_cons(3)).
          to include(['--ro-bind', File.dirname(job.input),
                      File.dirname(job.input)])
        expect(args.last(2)).to eq([job.input, '-'])
      end
    end

    it 'gives the step only the environment it sets' do
      ENV['SANDBOX_SPEC_SECRET'] = 'leaked'
      fake_bwrap('echo "{}" >&3; env; printf "%s\n" "$@"')
      out = AlaveteliSandbox.job do |job|
        job.run('pdftotext', job.input, '-', env: { 'LANG' => 'C' }).stdout
      end
      expect(out).not_to include('SANDBOX_SPEC_SECRET')
      expect(out.lines(chomp: true).each_cons(3)).
        to include(%w[--setenv LANG C])
    ensure
      ENV.delete('SANDBOX_SPEC_SECRET')
    end

    it 'seeds a private LibreOffice profile in /tmp via --file, replacing ' \
       'any UserInstallation argument' do
      fake_bwrap('echo "{}" >&3; cat <&5; printf "\n"; printf "%s\n" "$@"')
      AlaveteliSandbox.job do |job|
        out = job.run('libreoffice', '--headless',
                      '-env:UserInstallation=file:///tmp/theirs').stdout
        args = out.lines(chomp: true)
        expect(out).to include('DisableMacrosExecution')
        expect(args).to include(
          '-env:UserInstallation=file:///tmp/.libreoffice'
        )
        expect(args).not_to include('-env:UserInstallation=file:///tmp/theirs')
        expect(args.each_cons(3)).to include(
          ['--file', '5', '/tmp/.libreoffice/user/registrymodifications.xcu']
        )
      end
    end

    it 'gives Java (pdftk) explicit memory sizes that fit its limit' do
      fake_bwrap('echo "{}" >&3; printf "%s\n" "$@"')
      AlaveteliSandbox.job do |job|
        args = job.run('pdftk', job.input, 'output', '-').
               stdout.lines(chomp: true)
        expect(args.each_cons(3)).to include(
          ['--setenv', 'JAVA_TOOL_OPTIONS', described_class::JAVA_OPTIONS]
        )
        expect(args).to include("--as=#{described_class::JAVA_MEMORY}")
      end
    end

    it 'gives the sandbox blocking info-write and pause-read descriptors' do
      fake_bwrap(<<~SH)
        exec /usr/bin/python3 -c 'import fcntl,json,os; flags={str(fd): bool(fcntl.fcntl(fd, fcntl.F_GETFL) & os.O_NONBLOCK) for fd in (3,4)}; os.write(3,b"{}"); os.read(4,1); print(json.dumps(flags))'
      SH
      AlaveteliSandbox.job do |job|
        result = job.run('pdftotext', job.input, '-')
        expect(JSON.parse(result.stdout)).to eq('3' => false, '4' => false)
      end
    end

    it 'refuses, without running it, a step whose sandbox shares our PID namespace' do
      allow(AlaveteliSandbox::ProcessRunner).
        to receive(:confirm_namespace?).and_call_original
      # Force time for the stand-in to attempt its pause read before refusal.
      # A nonblocking inherited pipe would let its shell advance on EAGAIN.
      allow_any_instance_of(AlaveteliSandbox::ProcessRunner).
        to receive(:namespace_of).and_wrap_original do |original, *args|
          sleep 0.1
          original.call(*args)
        end
      expect(Rails.logger).to receive(:warn).with(/sandbox_unavailable/)
      fake_bwrap('echo "{\"child-pid\": $$}" >&3; ' \
                 'head -c1 <&4 >/dev/null; touch ran')
      AlaveteliSandbox.job do |job|
        expect { job.run('pdftotext', job.input, '-') }.
          to raise_error(AlaveteliSandbox::Refused, /could not start/)
        sleep 0.2
        expect(File.exist?(job.scratch('ran'))).to be false
      end
    end

    it 'never releases a step whose sandbox is still setting up when the wait runs out' do
      allow(AlaveteliSandbox::ProcessRunner).
        to receive(:confirm_namespace?).and_call_original
      fake_bwrap('sleep 2; echo "{}" >&3; head -c1 <&4 >/dev/null && touch ran')
      AlaveteliSandbox.job do |job|
        expect { job.run('pdftotext', job.input, '-', timeout: 1) }.
          to raise_error(AlaveteliSandbox::Refused, /could not start/)
        sleep 2.5
        expect(File.exist?(job.scratch('ran'))).to be false
      end
    end

    it 'passes a pause descriptor to bubblewrap' do
      fake_bwrap('echo "{}" >&3; printf "%s\n" "$@"')
      AlaveteliSandbox.job do |job|
        args = job.run('pdftotext', job.input, '-').stdout.lines(chomp: true)
        expect(args.each_cons(2)).to include(%w[--block-fd 4])
      end
    end

    it 'refuses Ghostscript' do
      expect { AlaveteliSandbox.job { |job| job.run('gs', '--version') } }.
        to raise_error(AlaveteliSandbox::Refused, /not_allowed/)
    end

    it 'refuses, and logs, when bubblewrap cannot set up the sandbox' do
      fake_bwrap('echo "bwrap: setting up uid map: Permission denied" >&2; ' \
                 'exit 1')
      expect(Rails.logger).
        to receive(:warn).with(/sandbox_unavailable.*uid map/)
      expect do
        AlaveteliSandbox.job { |job| job.run('pdftotext', job.input, '-') }
      end.to raise_error(AlaveteliSandbox::Refused, /could not start/)
    end

    it 'reports a converter failure as Failed, not a refusal' do
      fake_bwrap('echo "{}" >&3; echo "Syntax Error" >&2; exit 1')
      expect do
        AlaveteliSandbox.job { |job| job.run('pdftotext', job.input, '-') }
      end.to raise_error(AlaveteliSandbox::Failed)
    end

    it 'does not let child stderr spoof sandbox_failed? or skip audit!' do
      fake_bwrap('echo "{}" >&3; ln -s /etc/passwd link; ' \
                 'echo "bwrap: spoofed" >&2; exit 1')
      expect do
        AlaveteliSandbox.job { |job| job.run('pdftotext', job.input, '-') }
      end.to raise_error(AlaveteliSandbox::Failed, /unexpected link/)

      fake_bwrap('echo "{}" >&3; echo "bwrap: spoofed" >&2; exit 1')
      expect do
        AlaveteliSandbox.job { |job| job.run('pdftotext', job.input, '-') }
      end.to raise_error(AlaveteliSandbox::Failed, /exit 1/)
    end

    it 'refuses, never running unsandboxed, when bubblewrap is missing' do
      FileUtils.rm_f(bwrap)
      expect(Rails.logger).to receive(:warn).with(/sandbox_unavailable/)
      expect do
        AlaveteliSandbox.job { |job| job.run('pdftotext', job.input, '-') }
      end.to raise_error(AlaveteliSandbox::Refused, /could not start/)
    end
  end
end

RSpec.describe AlaveteliSandbox::ProcessRunner do
  # A live process can name itself to look like a zombie in /proc/PID/stat;
  # the drain must still see it as live.
  it 'reads a process state after its name, whatever the name' do
    pid = Process.spawn('sh', '-c',
                        'printf "x) Z y" > /proc/$$/comm; sleep 5 & wait',
                        pgroup: true)
    sleep 0.3
    expect(File.read("/proc/#{pid}/comm")).to include(') Z')
    runner = described_class.new(%w[true], chdir: '/', timeout: 1,
                                           stdout_limit: 1, stderr_limit: 1)
    expect(runner.send(:state_of, pid.to_s)).to eq('S')
  ensure
    if pid
      begin
        Process.kill('KILL', -pid)
        Process.wait(pid)
      rescue SystemCallError
        nil
      end
    end
  end

  it 'stops reading at a stdout overflow when stderr has output too' do
    # Wait until both pipes are readable so select sees them in one pass.
    allow(IO).to receive(:select).and_wrap_original do |select, readers, *rest|
      Array(readers).each { |io| io.wait_readable(5) }
      select.call(readers, *rest)
    end
    runner = described_class.new(
      ['/bin/sh', '-c', 'echo problem >&2; echo 0123456789'],
      chdir: '/', timeout: 5, stdout_limit: 5, stderr_limit: 100
    )

    result = runner.run

    expect(result.stdout_overflow).to be true
    expect(result.stdout).to eq('01234')
  end
end

RSpec.describe AlaveteliSandbox::Bubblewrap do
  subject(:argv) do
    described_class.argv(
      bwrap: '/usr/bin/bwrap', input_dir: '/run/c/job-1/in',
      scratch_dir: '/run/c/job-1/scratch',
      command: ['/usr/bin/pdftotext', 'x'],
      limits: AlaveteliSandbox::Job::STEP_DEFAULTS
    )
  end

  def pairs(flag)
    argv.each_index.select { |i| argv[i] == flag }.map { |i| argv[i + 1, 2] }
  end

  it 'starts with bubblewrap and ends with the command under prlimit' do
    expect(argv.first).to eq('/usr/bin/bwrap')
    expect(argv.last(2)).to eq(['/usr/bin/pdftotext', 'x'])
    expect(argv).to include('/usr/bin/prlimit', '--as=2147483648',
                            '--nproc=256', '--cpu=120')
  end

  it 'passes --seccomp when seccomp is enabled' do
    with_seccomp = described_class.argv(
      bwrap: '/usr/bin/bwrap', input_dir: '/run/c/job-1/in',
      scratch_dir: '/run/c/job-1/scratch',
      command: ['/usr/bin/pdftotext', 'x'],
      limits: AlaveteliSandbox::Job::STEP_DEFAULTS,
      seccomp: true
    )
    expect(with_seccomp.each_cons(2)).to include(%w[--seccomp 6])
  end

  it 'unshares everything, including the user namespace, explicitly' do
    expect(argv).to include('--unshare-all', '--unshare-user',
                            '--disable-userns', '--die-with-parent',
                            '--new-session', '--clearenv')
  end

  it 'binds the input read-only and only the scratch area writable' do
    expect(pairs('--ro-bind')).
      to include(['/run/c/job-1/in', '/run/c/job-1/in'])
    expect(pairs('--bind')).
      to eq([['/run/c/job-1/scratch', '/run/c/job-1/scratch']])
  end

  it 'never binds secrets or the whole of /etc, /run or /srv' do
    bound = (pairs('--ro-bind') + pairs('--ro-bind-try') + pairs('--bind')).
            map(&:first)
    expect(bound).not_to include('/etc', '/run', '/srv', '/home',
                                 '/var/lib/alaveteli-app')
    expect(bound.grep(%r{\A/(srv|home|root|run/[^c])})).to be_empty
  end
end

RSpec.describe AlaveteliSandbox::Seccomp do
  it 'compiles a valid BPF filter for x86_64 and aarch64' do
    { x86_64: [0xC000003E, 101, 321, 425],
      aarch64: [0xC00000B7, 117, 280, 425] }.each do |arch, (id, *nrs)|
      bpf = described_class.bpf(arch: arch)
      insns = (0...(bpf.bytesize / 8)).map do |i|
        bpf.byteslice(i * 8, 8).unpack('S<CCL<')
      end
      expect(insns.first).to eq([0x20, 0, 0, 4])
      expect(insns[1]).to eq([0x15, 0, insns.size - 3, id])
      expect(insns[2]).to eq([0x20, 0, 0, 0])
      expect(insns.last(2)).to eq([[0x06, 0, 0, 0x7FFF0000],
                                   [0x06, 0, 0, 0x00050001]])
      matched = insns[3...-2].map(&:last)
      expect(matched).to include(*nrs)
      if arch == :x86_64
        expect(insns[3]).to eq([0x35, insns.size - 5, 0, 0x40000000])
      end
    end
    expect(described_class.bpf(arch: :unknown)).to be_nil
  end
end

RSpec.describe AlaveteliExternalCommand do
  it 'refuses to run anything while the sandbox is required' do
    allow(AlaveteliConfiguration).
      to receive(:sandbox_converters).and_return('required')
    expect(Rails.logger).to receive(:warn).with(/not_routed program=echo/)
    expect(ExternalCommand).not_to receive(:new)
    expect(described_class.run('echo', 'hi')).to be_nil
  end
end
