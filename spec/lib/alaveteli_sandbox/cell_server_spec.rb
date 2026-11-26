require 'spec_helper'

# In-process CellServer tests with a fake bwrap that prints its arguments;
# real cells are tested in spec/integration/converter_cells_spec.rb.
RSpec.describe AlaveteliSandbox::CellServer do
  let(:dir) { Dir.mktmpdir('cell-server-spec') }
  let(:volume) { File.join(dir, 'volume') }
  let(:bwrap) { File.join(dir, 'bwrap') }
  let(:job) { File.join(volume, 'job-abc') }
  let(:limits) { AlaveteliSandbox::Job::STEP_DEFAULTS.merge(timeout: 5) }

  before do
    FileUtils.mkdir_p([File.join(job, 'in'), File.join(job, 'scratch')])
    File.write(bwrap, <<~SH)
      #!/bin/sh
      echo '{"child-pid": 2}' >&3
      printf '%s\\n' "$@"
    SH
    File.chmod(0o755, bwrap)
    # The stand-in makes no PID namespace to confirm.
    allow(AlaveteliSandbox::ProcessRunner).
      to receive(:confirm_namespace?).and_return(false)
    allow_any_instance_of(described_class).to receive(:warn)
  end

  after { FileUtils.remove_entry(dir) }

  def cell(kind = 'pdf', slots: 2, gems: [])
    described_class.new(kind: kind, socket: File.join(dir, "#{kind}.sock"),
                        volume: volume, bwrap: bwrap, slots: slots,
                        root: Rails.root.to_s, gems: gems)
  end

  def request(**fields)
    { 'release' => AlaveteliSandbox::Cell.release, 'job' => 'job-abc',
      'run' => 'program', 'program' => 'pdftotext', 'args' => %w[a -],
      'limits' => limits }.merge(fields.stringify_keys)
  end

  def answer_to(line, from: cell)
    ours, theirs = UNIXSocket.pair
    ours.write(line)
    from.handle(theirs)
    theirs.close
    first, output = ours.read.split("\n", 2)
    [JSON.parse(first), output]
  ensure
    ours.close
  end

  def answer(from: cell, **fields)
    answer_to("#{JSON.generate(request(**fields))}\n", from: from)
  end

  def bubblewrap_arguments(**fields)
    header, output = answer(**fields)
    expect(header).not_to include('error')
    output.lines(chomp: true)
  end

  def refusal(**fields)
    answer(**fields).first['error']
  end

  it 'refuses to be a kind of cell there isn’t' do
    expect { cell('shell') }.to raise_error(ArgumentError, /unknown kind/)
  end

  it 'runs one of its programs in bubblewrap, on the job’s own directories' do
    header, output = answer
    arguments = output.lines(chomp: true)

    expect(header).to include('exitstatus' => 0, 'timed_out' => false,
                              'stdout_size' => output.bytesize)
    expect(arguments).to include('--unshare-all', '--clearenv')
    expect(arguments.each_cons(3)).
      to include(['--ro-bind', "#{job}/in", "#{job}/in"],
                 ['--bind', "#{job}/scratch", "#{job}/scratch"])
    expect(arguments.last(3)).to match([%r{\A/usr/.*pdftotext\z}, 'a', '-'])
  end

  describe 'the programs it runs' do
    it 'refuses the other cell’s programs' do
      expect(refusal(program: 'soffice')).
        to match(/soffice is not one of this cell's programs/)
      expect(answer(from: cell('office')).first['error']).
        to match(/pdftotext is not one of this cell's programs/)
    end

    it 'refuses a program on no list, before it looks at anything else' do
      expect(refusal(program: 'sh', args: ['-c', 'id'], job: 'job-gone',
                     limits: {})).
        to match(/sh is not one of this cell's programs/)
    end

    it 'runs the self-test’s program only for a self-test' do
      expect(refusal(program: 'true', args: [])).to match(/is not one of/)
      expect(bubblewrap_arguments(program: 'true', args: [],
                                  self_test: true).last).
        to match(%r{\A/usr/.*true\z})
    end

    it 'refuses a program that resolves outside /usr' do
      File.write(File.join(dir, 'pdftotext'), "#!/bin/sh\n")
      File.chmod(0o755, File.join(dir, 'pdftotext'))
      allow(ENV).to receive(:[]).and_call_original
      allow(ENV).to receive(:[]).with('PATH').and_return(dir)

      expect(refusal).to match(%r{resolves outside /usr})
    end

    it 'refuses a kind of step it doesn’t know' do
      expect(refusal(run: 'shell')).to eq('unknown kind of step')
    end

    it 'refuses arguments that aren’t a list' do
      expect(refusal(args: { '-c' => 'id' })).
        to eq('the arguments are not a list')
      expect(refusal(args: '-c id')).to eq('the arguments are not a list')
    end
  end

  describe 'the job it runs on' do
    it 'refuses a name that isn’t a job’s' do
      ['../etc', 'job-abc/../..', 'job-', '', 'jobs'].each do |name|
        expect(refusal(job: name)).to eq('bad job name')
      end
    end

    it 'refuses a job that isn’t on the volume' do
      expect(refusal(job: 'job-gone')).
        to eq('no such job on the conversion volume')
    end

    it 'refuses a job that is a link, or isn’t the app’s' do
      File.symlink(job, File.join(volume, 'job-link'))
      expect(refusal(job: 'job-link')).
        to eq('the job is not a directory of the app’s')

      theirs = instance_double(File::Stat, directory?: true,
                                           uid: Process.euid + 1)
      allow(File).to receive(:lstat).and_call_original
      allow(File).to receive(:lstat).with(job).and_return(theirs)
      expect(refusal).to eq('the job is not a directory of the app’s')
    end

    it 'refuses a job without its directories' do
      Dir.rmdir(File.join(job, 'scratch'))
      expect(refusal).to eq('the job has no scratch directory')
    end
  end

  describe 'the limits it runs under' do
    it 'caps each limit, whatever is asked' do
      most = described_class::MOST
      asked = most.transform_values { |value| value * 10 }
      arguments = bubblewrap_arguments(limits: asked)

      expect(arguments).to include(
        "--as=#{most[:memory]}", "--fsize=#{most[:file_size]}",
        "--nofile=#{most[:open_files]}", "--nproc=#{most[:processes]}",
        "--cpu=#{most[:timeout]}"
      )
      expect(arguments.each_cons(2)).
        to include(['--size', most[:tmp_size].to_s])
    end

    it 'caps --nproc per cell' do
      most = described_class::MOST
      asked = most.merge(processes: 9999)
      gems = %w[/gems/mail-2.9.1/lib]
      mail_cell = cell('mail', gems: gems)

      expect(bubblewrap_arguments(limits: asked)).to include('--nproc=512')
      _, output = answer(from: mail_cell, run: 'mail_read',
                         input_name: 'mail.eml', tools: true, bodies: 'all',
                         stored: false,
                         worker: AlaveteliSandbox::MailStep.release(
                           Rails.root.to_s, gems
                         ),
                         limits: asked)
      expect(output.lines(chomp: true)).to include('--nproc=128')
    end

    it 'caps no limit below what the app’s own callers ask for' do
      most = described_class::MOST
      expect(most[:stdout]).to be >= PDFRedactor::MAX_BYTES
      expect(most[:stdout]).to be >= AttachmentManagement::Command::MAX_OUTPUT
      expect(most[:memory]).
        to be >= AttachmentManagement::Command::LIBREOFFICE_MEMORY
      expect(most[:memory]).to be >= AlaveteliSandbox::Job::JAVA_MEMORY
      expect(most[:file_size]).to be >= MailHandler::TNEF_MAX_BYTES
      expect(most[:timeout]).
        to be >= AlaveteliSandbox::RedactorStep::LIMITS[:timeout]
      AlaveteliSandbox::Job::STEP_DEFAULTS.except(:env).each do |limit, value|
        expect(most[limit]).to be >= value
      end
    end

    it 'keeps a limit below the cap' do
      expect(bubblewrap_arguments).to include("--as=#{limits[:memory]}")
    end

    it 'refuses a step that leaves a limit out' do
      expect(refusal(limits: limits.except(:memory))).to match(/memory/)
    end

    it 'refuses a limit that isn’t a positive number' do
      expect(refusal(limits: limits.merge(memory: 0))).
        to eq('the memory limit must be positive')
      expect(refusal(limits: limits.merge(timeout: -1))).
        to eq('the timeout limit must be positive')
      expect(refusal(limits: limits.merge(stdout: 'lots'))).to match(/invalid/)
      expect(refusal(limits: 'none')).to eq('the limits are not an object')
    end

    it 'allows only explicitly allowlisted environment variables per program' do
      elinks = bubblewrap_arguments(
        program: 'elinks', args: %w[-dump a],
        limits: limits.merge(env: { 'LANG' => 'C' })
      )
      expect(elinks.each_cons(3)).to include(%w[--setenv LANG C])

      tesseract = bubblewrap_arguments(
        program: 'tesseract', args: %w[a stdout],
        limits: limits.merge(env: { 'OMP_THREAD_LIMIT' => '1' })
      )
      expect(tesseract.each_cons(3)).
        to include(%w[--setenv OMP_THREAD_LIMIT 1])

      expect(refusal(program: 'elinks', args: %w[-dump a],
                     limits: limits.merge(env: { 'LANG' => 'en_US.UTF-8' }))).
        to eq('invalid value for LANG')
      expect(refusal(program: 'tesseract', args: %w[a stdout],
                     limits: limits.merge(
                       env: { 'OMP_THREAD_LIMIT' => '100' }
                     ))).to eq('invalid value for OMP_THREAD_LIMIT')
      expect(refusal(limits: limits.merge(
        env: { 'OMP_THREAD_LIMIT' => '1' }
      ))).to eq('the step may not set OMP_THREAD_LIMIT')
    end

    it 'refuses disallowed environment variables' do
      %w[
        LD_PRELOAD LD_LIBRARY_PATH PATH HOME TMPDIR MAGICK_CONFIGURE_PATH
        RUBYOPT RUBYLIB PERL5OPT PERL5LIB JAVA_TOOL_OPTIONS _JAVA_OPTIONS
        OPENSSL_CONF GCONV_PATH FONTCONFIG_FILE TESSDATA_PREFIX XDG_CONFIG_HOME
        lower A=B
      ].each do |name|
        expect(refusal(limits: limits.merge(env: { name => 'x' }))).
          to eq("the step may not set #{name}")
      end
    end

    it 'injects JAVA_TOOL_OPTIONS and Java memory for pdftk itself' do
      arguments = bubblewrap_arguments(program: 'pdftk', args: %w[a output -])
      expect(arguments.each_cons(3)).to include(
        ['--setenv', 'JAVA_TOOL_OPTIONS',
         AlaveteliSandbox::Bubblewrap::JAVA_OPTIONS]
      )
      expect(arguments).to include(
        "--as=#{AlaveteliSandbox::Bubblewrap::JAVA_MEMORY}"
      )
    end

    it 'injects LibreOffice’s seeded /tmp profile and rejects -env: flags' do
      office = cell('office')
      header, output = answer(
        from: office, program: 'soffice',
        args: %w[--headless -env:UserInstallation=file:///tmp/evil a]
      )
      expect(header).not_to include('error')
      arguments = output.lines(chomp: true)
      expect(arguments).to include(
        '-env:UserInstallation=file:///tmp/.libreoffice'
      )
      expect(arguments).not_to include('-env:UserInstallation=file:///tmp/evil')
      expect(arguments.each_cons(3)).to include(
        ['--file', '5', '/tmp/.libreoffice/user/registrymodifications.xcu']
      )

      bad = answer(from: office, program: 'soffice',
                   args: %w[--headless -env:UNO_TEST=1 a])
      expect(bad.first['error']).
        to eq('the step may not set LibreOffice environment flags')
    end
  end

  describe 'who it answers' do
    it 'refuses an app from another release' do
      expect(refusal(release: 'another')).to match(/different releases/)
      expect(refusal(release: nil)).to match(/different releases/)
    end

    it 'refuses anyone but the user who owns the volume' do
      owner = instance_double(File::Stat, uid: Process.euid + 1)
      allow(File).to receive(:stat).and_call_original
      allow(File).to receive(:stat).with(volume).and_return(owner)

      expect(refusal).to eq('not the app’s user')
    end

    it 'refuses a request that isn’t one' do
      expect(answer_to("pdftotext a -\n").first['error']).to match(/unexpected/)
      expect(answer_to("[1, 2]\n").first['error']).
        to eq('the request is not an object')
    end

    it 'refuses anyone else before it reads what they send' do
      owner = instance_double(File::Stat, uid: Process.euid + 1)
      allow(File).to receive(:stat).and_call_original
      allow(File).to receive(:stat).with(volume).and_return(owner)
      ours, theirs = UNIXSocket.pair
      ours.write('{')

      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      cell.handle(theirs)
      theirs.close

      expect(Process.clock_gettime(Process::CLOCK_MONOTONIC) - started).
        to be < described_class::REQUEST_SECONDS
      expect(JSON.parse(ours.read)).to eq('error' => 'not the app’s user')
    end

    it 'refuses a request that doesn’t all arrive in time, or is too long' do
      stub_const("#{described_class}::REQUEST_SECONDS", 0.2)
      expect(answer_to('{"run": "program"').first['error']).
        to eq('no request was sent')

      stub_const("#{described_class}::REQUEST_BYTES", 100)
      expect(answer_to("#{'x' * 200}\n").first['error']).
        to eq('the request is too long')
    end

    it 'refuses a step when it has no room for another process' do
      single = cell
      allow(single).to receive(:fork).and_raise(Errno::EAGAIN)
      ours, theirs = UNIXSocket.pair
      ours.write("#{JSON.generate(request)}\n")

      expect(single.send(:start_handler, theirs, theirs)).to be_nil
      theirs.close
      expect(JSON.parse(ours.read)['error']).
        to match(/busy: no room for another step/)
    end

    it 'refuses a connection that sends nothing' do
      stub_const("#{described_class}::REQUEST_SECONDS", 0.1)
      ours, theirs = UNIXSocket.pair
      cell.handle(theirs)
      theirs.close

      expect(JSON.parse(ours.read)).to eq('error' => 'no request was sent')
    end

    it 'doesn’t run a step for an app that has gone' do
      File.write(bwrap, "#!/bin/sh\ntouch #{dir}/ran\n")
      ours, theirs = UNIXSocket.pair
      ours.write("#{JSON.generate(request)}\n")
      ours.close
      cell.handle(theirs)

      expect(File).not_to exist(File.join(dir, 'ran'))
    end
  end

  describe 'what a step leaves' do
    it 'is opened to the group, whatever modes the step gave it' do
      File.write(bwrap, <<~SH)
        #!/bin/sh
        echo '{"child-pid": 2}' >&3
        mkdir -p closed/inner
        echo x > closed/inner/file
        echo x > private
        chmod 600 closed/inner/file private
        chmod 700 closed/inner
        chmod 000 closed
        ln -s /etc/passwd link
      SH
      scratch = File.join(job, 'scratch')
      passwd = File.stat('/etc/passwd').mode

      expect(answer.first).not_to include('error')
      modes = %w[closed closed/inner closed/inner/file private].map do |name|
        format('%o', File.stat(File.join(scratch, name)).mode & 0o7777)
      end
      expect(modes).to eq(%w[2770 2770 660 660])
      expect(File.stat('/etc/passwd').mode).to eq(passwd)
    end
  end

  describe 'steps at once' do
    it 'refuses a step that finds no free slot within its time limit' do
      limits[:timeout] = 1
      single = cell(slots: 1)
      held = File.open(File.join(dir, 'pdf.sock.slot0'),
                       File::RDWR | File::CREAT)
      held.flock(File::LOCK_EX)

      expect(answer(from: single).first['error']).
        to eq('busy: all 1 slots were in use for 1 seconds')

      held.close
      expect(answer(from: single).first).not_to include('error')
    end

    it 'gives a slot back when its step is done' do
      single = cell(slots: 1)
      2.times { expect(answer(from: single).first).not_to include('error') }
    end
  end

  describe 'ImageMagick’s policy' do
    def magick_lists(listing, status: 0, says: true)
      File.write(File.join(dir, 'listing'), listing)
      File.write(bwrap, <<~SH)
        #!/bin/sh
        echo '{"child-pid": 2}' >&3
        printf '%s\\n' "$@" > #{dir}/arguments
        cat #{dir}/listing
        #{"echo 'magick: no' >&2" if says}
        exit #{status}
      SH
    end

    let(:required) do
      file_fixture('imagemagick-policy-listing-required.txt').read
    end
    let(:debian) { file_fixture('imagemagick-policy-listing-debian.txt').read }

    it 'is asked for in the sandbox a step gets' do
      magick_lists(required)
      cell.image_policy_problem

      arguments = File.readlines(File.join(dir, 'arguments'), chomp: true)
      expect(arguments).to include('--unshare-all', '--clearenv')
      expect(arguments.last(3)).
        to match([%r{\A/usr/.*magick\z}, '-list', 'policy'])
    end

    it 'is no problem when it is the required one' do
      magick_lists(required)
      expect(cell.image_policy_problem).to be_nil
    end

    it 'is a problem when it is Debian’s' do
      magick_lists(debian)
      expect(cell.image_policy_problem).to match(/without delegate none \*/)
    end

    it 'is a problem when ImageMagick can’t be asked' do
      magick_lists(required, status: 1)
      expect(cell.image_policy_problem).
        to eq("ImageMagick's policy could not be read: magick: no")

      magick_lists(required, status: 3, says: false)
      expect(cell.image_policy_problem).
        to eq("ImageMagick's policy could not be read: exit 3")
    end

    it 'isn’t asked for by the Office cell, which runs no ImageMagick' do
      magick_lists(debian)
      expect(AlaveteliSandbox::ProcessRunner).not_to receive(:new)
      expect(cell('office').image_policy_problem).to be_nil
    end

    it 'stops the PDF cell serving when it isn’t the required one' do
      magick_lists(debian)

      expect { cell.serve }.to raise_error(SystemExit).and(
        output(/sandbox cell \(pdf\): not serving: ImageMagick's policy/).
          to_stderr
      )
      expect(File).not_to exist(File.join(dir, 'pdf.sock'))
    end
  end

  describe 'PDFRedactor’s worker' do
    let(:redactor) do
      { run: 'pdf_redactor', mode: 'scan', input_name: 'input.pdf',
        ocr: false, depth: 0, regexp_timeout: 1.5,
        worker: AlaveteliSandbox::RedactorStep.release }
    end

    it 'runs its own copy of the worker, under the worker’s limits' do
      arguments = bubblewrap_arguments(
        **redactor, limits: limits.merge(timeout: 600, memory: 3 * (1024**3))
      )
      worker = Rails.root.join('script/pdf_redactor_worker.rb').to_s
      step = AlaveteliSandbox::RedactorStep::LIMITS

      expect(arguments.last(10)).to eq(
        ['--disable-gems', worker, 'scan', "#{job}/in/input.pdf",
         "#{job}/scratch/rules.json", "#{job}/scratch/output.pdf",
         "#{job}/scratch/report.json", '0', '0', '1.5']
      )
      expect(arguments).to include("--as=#{step[:memory]}",
                                   "--cpu=#{step[:timeout]}")
      lib = Rails.root.join('gems/pdf_redactor/lib').to_s
      expect(arguments.each_cons(3)).to include(
        ['--ro-bind', worker, worker], ['--ro-bind', lib, lib]
      )
    end

    it 'is refused by the Office cell' do
      expect(answer(from: cell('office'), **redactor).first['error']).
        to eq('the PDF redactor is not one of this cell’s programs')
    end

    it 'refuses a mode, input name, depth, timeout or env that isn’t valid' do
      expect(refusal(**redactor, mode: 'shell')).to eq('unknown redactor mode')
      expect(refusal(**redactor, input_name: '../x')).to eq('bad input name')
      expect(refusal(**redactor, input_name: 'a..b')).to eq('bad input name')
      expect(refusal(**redactor, depth: 'deep')).to match(/invalid value/)
      [-1, 4].each do |depth|
        expect(refusal(**redactor, depth: depth)).
          to eq('depth must be between 0 and 3')
      end
      [0, -1, 'NaN', 'Infinity'].each do |timeout|
        expect(refusal(**redactor, regexp_timeout: timeout)).
          to eq('regexp_timeout must be a positive number')
      end
      expect(refusal(**redactor, limits: limits.merge(env: { 'LANG' => 'C' }))).
        to eq('the step may not set LANG')
    end

    it 'refuses an app whose copy of the worker differs' do
      expect(refusal(**redactor, worker: 'another')).
        to match(/copy of this worker and this cell’s differ/)
      expect(refusal(**redactor, worker: nil)).
        to match(/copy of this worker and this cell’s differ/)
    end
  end

  describe 'the mail worker' do
    let(:gems) { %w[/gems/mail-2.9.1/lib /gems/date-3.6.0] }
    let(:mail_cell) { cell('mail', gems: gems) }
    let(:read) do
      { run: 'mail_read', input_name: 'mail.eml', tools: true,
        bodies: 'all', stored: false,
        worker: AlaveteliSandbox::MailStep.release(Rails.root.to_s, gems) }
    end

    def mail_refusal(from: mail_cell, **fields)
      answer(from: from, **read, **fields).first['error']
    end

    it 'runs its own copy of the worker with its own gems, under the ' \
       'worker’s limits' do
      header, output = answer(
        from: mail_cell, **read,
        limits: limits.merge(timeout: 600, memory: 3 * (1024**3))
      )
      expect(header).not_to include('error')
      arguments = output.lines(chomp: true)
      worker = Rails.root.join('script/mail_worker.rb').to_s
      step = AlaveteliSandbox::MailStep::LIMITS

      expect(arguments.last(10)).to eq(
        ['--disable-gems', '-I', gems[0], '-I', gems[1], worker,
         "#{job}/in/mail.eml", "#{job}/scratch", '1', 'all']
      )
      expect(arguments).to include("--as=#{step[:memory]}",
                                   "--cpu=#{step[:timeout]}")
      expect(arguments.each_cons(3)).to include(['--ro-bind', worker, worker])
      expect(arguments.each_cons(3)).
        to include(['--ro-bind', gems[0], gems[0]])
    end

    it 'names a stored file to match only when told there is one' do
      _, output = answer(from: mail_cell, **read, stored: true)
      expect(output.lines(chomp: true).last).to eq("#{job}/scratch/stored")
    end

    it 'takes the gems from its own settings, whatever it is sent' do
      _, output = answer(from: mail_cell, **read,
                         gems: ['/tmp/evil'], gem_directories: ['/tmp/evil'])
      expect(output).not_to include('/tmp/evil')
    end

    it 'is refused by the PDF and Office cells' do
      %w[pdf office].each do |kind|
        expect(mail_refusal(from: cell(kind, gems: gems))).
          to eq('the mail worker is not one of this cell’s programs')
      end
    end

    it 'is refused by a mail cell that has not been told the gems' do
      expect(mail_refusal(from: cell('mail'))).
        to eq('this cell has not been told the mail worker’s gems')
    end

    it 'refuses an app whose copy of the worker, or whose gems, differ' do
      other = AlaveteliSandbox::MailStep.release(
        Rails.root.to_s, %w[/gems/mail-2.9.2/lib /gems/date-3.6.0]
      )
      [other, 'another', nil].each do |worker|
        expect(mail_refusal(worker: worker)).
          to match(/copy of this worker and this cell’s differ/)
      end
    end

    it 'tells the worker to run no tools when the app says so' do
      _, output = answer(from: mail_cell, **read, tools: false)
      expect(output.lines(chomp: true).last(2)).to eq(%w[0 all])
    end

    it 'tells the worker which parts’ bytes to leave: all, none or one ' \
       'part’s' do
      digest = 'd41d8cd98f00b204e9800998ecf8427e'
      ['none', digest].each do |bodies|
        _, output = answer(from: mail_cell, **read, bodies: bodies)
        expect(output.lines(chomp: true).last).to eq(bodies)
      end
      ['--help', '../x', "#{digest}0", 7, nil].each do |bodies|
        expect(mail_refusal(bodies: bodies)).
          to eq('bodies must be all, none or a part’s digest')
      end
    end

    it 'refuses an input name that isn’t one, and a stored or tools that ' \
       'isn’t true or false' do
      expect(mail_refusal(input_name: '../x')).to eq('bad input name')
      expect(mail_refusal(stored: '/etc/passwd')).
        to match(/must each be true or false/)
      expect(mail_refusal(tools: '--help')).
        to match(/must each be true or false/)
      expect(answer(from: mail_cell, **read.except(:tools)).first['error']).
        to match(/key not found/)
    end
  end

  describe 'the Office worker' do
    let(:gems) { %w[/gems/nokogiri-1.19.7/lib /gems/rubyzip-3.7.0/lib] }
    let(:office_cell) { cell('office', gems: gems) }
    let(:sheets) do
      { max_rows: 2000, max_columns: 60, max_cells: 200_000,
        max_read_cells: 2_000_000 }
    end
    let(:read) do
      { run: 'office_read', input_name: 'file.xlsx',
        sections: %w[guard strings], sheets: nil,
        worker: AlaveteliSandbox::OfficeStep.release(Rails.root.to_s, gems) }
    end

    def office_refusal(from: office_cell, **fields)
      answer(from: from, **read, **fields).first['error']
    end

    def worker_arguments(**fields)
      header, output = answer(from: office_cell, **read, **fields)
      expect(header).not_to include('error')
      output.lines(chomp: true)
    end

    it 'runs its own copy of the worker with its own gems, under the ' \
       'worker’s limits' do
      arguments = worker_arguments(
        limits: limits.merge(timeout: 600, memory: 3 * (1024**3))
      )
      worker = Rails.root.join('script/office_worker.rb').to_s
      step = AlaveteliSandbox::OfficeStep::LIMITS

      expect(arguments.last(9)).to eq(
        ['--disable-gems', '-I', gems[0], '-I', gems[1], worker,
         "#{job}/in/file.xlsx", "#{job}/scratch", 'guard,strings']
      )
      expect(arguments).to include("--as=#{step[:memory]}",
                                   "--cpu=#{step[:timeout]}")
      expect(arguments.each_cons(3)).to include(['--ro-bind', worker, worker])
      expect(arguments.each_cons(3)).
        to include(['--ro-bind', gems[0], gems[0]])
    end

    it 'gives the worker the sheets section’s limits' do
      expect(worker_arguments(sections: %w[sheets], sheets: sheets).last(5)).
        to eq(%w[sheets 2000 60 200000 2000000])
      whole = sheets.merge(max_rows: nil, max_columns: nil)
      expect(worker_arguments(sections: %w[sheets], sheets: whole).last(5)).
        to eq(%w[sheets none none 200000 2000000])
    end

    it 'gives the worker the zip_entries section’s limits and refuses bad ' \
       'ones' do
      zip = { max_entries: 500, max_entry: 1024, max_total: 4096 }
      expect(
        worker_arguments(sections: %w[guard zip_entries], zip: zip).last(4)
      ).to eq(%w[guard,zip_entries 500 1024 4096])
      expect(office_refusal(sections: %w[zip_entries], zip: nil)).
        to match(/needs max_entries/)
      expect(office_refusal(zip: zip)).to match(/zip_entries section only/)
    end

    it 'takes the gems from its own settings, whatever it is sent' do
      _, output = answer(from: office_cell, **read,
                         gems: ['/tmp/evil'], gem_directories: ['/tmp/evil'])
      expect(output).not_to include('/tmp/evil')
    end

    it 'is refused by the PDF and mail cells' do
      %w[pdf mail].each do |kind|
        expect(office_refusal(from: cell(kind, gems: gems))).
          to eq('the Office worker is not one of this cell’s programs')
      end
    end

    it 'is refused by an Office cell that has not been told the gems' do
      expect(office_refusal(from: cell('office'))).
        to eq('this cell has not been told the Office worker’s gems')
    end

    it 'still runs LibreOffice in an Office cell that has not been told ' \
       'the gems' do
      header, = answer(from: cell('office'), program: 'soffice',
                       args: %w[--version])
      expect(header).not_to include('error')
    end

    it 'refuses an app whose copy of the worker, or whose gems, differ' do
      other = AlaveteliSandbox::OfficeStep.release(
        Rails.root.to_s, %w[/gems/nokogiri-1.19.8/lib /gems/rubyzip-3.7.0/lib]
      )
      mail = AlaveteliSandbox::MailStep.release(Rails.root.to_s, gems)
      [other, mail, 'another', nil].each do |worker|
        expect(office_refusal(worker: worker)).
          to match(/copy of this worker and this cell’s differ/)
      end
    end

    it 'refuses sections that aren’t some of the worker’s, each once' do
      [%w[guard guard], %w[shell], ['guard,strings'], [], 'guard', nil,
       [7]].each do |sections|
        expect(office_refusal(sections: sections)).
          to match(/sections must be some of/)
      end
    end

    it 'refuses sheet limits that aren’t whole numbers in range, or that ' \
       'come without the sheets section' do
      [sheets.merge(max_rows: 0), sheets.merge(max_cells: 2_000_001),
       sheets.merge(max_read_cells: '20'), sheets.merge(max_cells: nil),
       sheets.except(:max_columns), sheets.merge(path: '/etc'), nil,
       'none'].each do |bad|
        expect(office_refusal(sections: %w[sheets], sheets: bad)).
          to match(/must be from 1 to|needs max_rows/)
      end
      expect(office_refusal(sheets: sheets)).to match(/sheets section only/)
    end

    it 'refuses an input name that isn’t one, and a read that leaves out ' \
       'its sections or sheets' do
      expect(office_refusal(input_name: '../x')).to eq('bad input name')
      expect(answer(from: office_cell, **read.except(:sections)).
             first['error']).to match(/key not found/)
      expect(answer(from: office_cell, **read.except(:sheets)).
             first['error']).to match(/key not found/)
    end
  end
end
