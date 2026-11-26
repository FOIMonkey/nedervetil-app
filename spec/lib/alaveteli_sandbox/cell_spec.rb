require 'spec_helper'

RSpec.describe AlaveteliSandbox::Cell do
  let(:dir) { Dir.mktmpdir('cell-spec') }
  let(:socket) { File.join(dir, 'pdf.sock') }
  let(:limits) { AlaveteliSandbox::Job::STEP_DEFAULTS.merge(timeout: 1) }
  let(:step) { { 'run' => 'program', 'program' => 'pdfinfo', 'args' => [] } }
  let(:requests) { [] }

  before do
    allow(AlaveteliConfiguration).to receive_messages(
      sandbox_converters: 'required', sandbox_pdf_cell: socket,
      sandbox_office_cell: File.join(dir, 'office.sock'),
      sandbox_mail_cell: File.join(dir, 'mail.sock')
    )
  end

  after do
    @listener&.kill
    FileUtils.remove_entry(dir)
  end

  def cell_answers(answer = nil)
    server = UNIXServer.new(socket)
    @listener = Thread.new do
      loop do
        connection = server.accept
        requests << JSON.parse(connection.gets)
        answer ? connection.write(answer) : yield(connection)
        connection.close
      end
    end
  end

  def header(**fields)
    JSON.generate({ 'exitstatus' => 0, 'termsig' => nil, 'info' => '{}',
                    'stdout_size' => 0, 'stderr_size' => 0 }.
                    merge(fields.stringify_keys))
  end

  def run
    described_class.run('pdf', step, job: 'job-abc', limits: limits)
  end

  def sockets(pdf, office, mail, mode: 'required')
    allow(AlaveteliConfiguration).to receive_messages(
      sandbox_converters: mode, sandbox_pdf_cell: pdf,
      sandbox_office_cell: office, sandbox_mail_cell: mail
    )
  end

  describe '.configuration_problem' do
    it 'is nil with no cell set, whatever the mode' do
      sockets('', ' ', '', mode: 'off')
      expect(described_class).not_to be_configured
      expect(described_class.configuration_problem).to be_nil
    end

    it 'is nil with all three set and the sandbox required' do
      sockets('/run/pdf.sock', '/run/office.sock', '/run/mail.sock')
      expect(described_class).to be_configured
      expect(described_class.configuration_problem).to be_nil
    end

    [['/run/pdf.sock', '/run/office.sock', ''],
     ['/run/pdf.sock', '', '/run/mail.sock'],
     ['', '/run/office.sock', '/run/mail.sock'],
     ['', '', '/run/mail.sock']].each do |set|
      it "reports #{set.count(&:present?)} of the three set without the " \
         "rest (#{set.inspect})" do
        sockets(*set)
        expect(described_class.configuration_problem).
          to match(/must all be set, or none/)
      end
    end

    it 'reports cells set without the sandbox required' do
      sockets('/run/pdf.sock', '/run/office.sock', '/run/mail.sock',
              mode: 'off')
      expect(described_class.configuration_problem).
        to match(/need SANDBOX_CONVERTERS: required/)
    end
  end

  describe '.release' do
    def checkout(worker: 'puts 1')
      root = File.join(dir, SecureRandom.hex(4))
      FileUtils.mkdir_p(File.join(root, 'lib/alaveteli_sandbox'))
      FileUtils.mkdir_p(File.join(root, 'script'))
      File.write(File.join(root, 'lib/alaveteli_sandbox/job.rb'), 'job')
      File.write(File.join(root, 'script/pdf_redactor_worker.rb'), worker)
      File.write(File.join(root, 'README.md'), SecureRandom.hex)
      root
    end

    it 'is the same for two checkouts with the same shared code' do
      expect(described_class.release(checkout)).
        to eq(described_class.release(checkout))
    end

    it 'differs when the sandbox’s code differs' do
      changed = checkout
      File.write(File.join(changed, 'lib/alaveteli_sandbox/job.rb'), 'jobs')

      expect(described_class.release(checkout)).
        not_to eq(described_class.release(changed))
    end

    # A cell is shown the sandbox and its own worker, not the other cells'
    # workers, so those are named apart from the release.
    it 'is the same whatever a worker’s code, which is named with its step' do
      other = checkout(worker: 'puts 2')

      expect(described_class.release(checkout)).
        to eq(described_class.release(other))
      expect(AlaveteliSandbox::RedactorStep.release(checkout)).
        not_to eq(AlaveteliSandbox::RedactorStep.release(other))
    end

    it 'includes the PDF gem’s font data in the PDF worker release' do
      first = checkout
      second = checkout
      [first, second].each_with_index do |root, index|
        data = File.join(root, 'gems/pdf_redactor/lib/pdf_redactor/data')
        FileUtils.mkdir_p(data)
        File.write(File.join(data, 'glyphlist.txt'), index.to_s)
      end

      step = AlaveteliSandbox::RedactorStep
      expect(step.release(first)).not_to eq(step.release(second))
    end

    it 'is the same in a checkout that holds only the sandbox' do
      root = File.join(dir, 'sandbox-only')
      Dir.glob(described_class::SHARED_CODE, base: Rails.root.to_s).
        each do |name|
          next unless File.file?(Rails.root.join(name))

          FileUtils.mkdir_p(File.dirname(File.join(root, name)))
          FileUtils.cp(Rails.root.join(name), File.join(root, name))
        end

      expect(described_class.release(root)).to eq(described_class.release)
    end
  end

  describe '.releases' do
    it 'names the sandbox’s code and each worker’s' do
      expect(described_class.releases).to eq(
        'cells' => described_class.release,
        'pdf' => AlaveteliSandbox::RedactorStep.release,
        'mail' => AlaveteliSandbox::MailStep.release(
          described_class::ROOT, AlaveteliSandbox::MailStep.gem_directories
        ),
        'office' => AlaveteliSandbox::OfficeStep.release(
          described_class::ROOT, AlaveteliSandbox::OfficeStep.gem_directories
        )
      )
    end

    # Deploy invariant: on-disk updates must not alter a memoized release.
    it 'keeps each name once taken, whatever happens to the files' do
      root = File.join(dir, 'kept')
      FileUtils.mkdir_p(File.join(root, 'lib/alaveteli_sandbox'))
      FileUtils.mkdir_p(File.join(root, 'lib/mail_handler'))
      FileUtils.mkdir_p(File.join(root, 'script'))
      files = %w[lib/alaveteli_sandbox/job.rb script/pdf_redactor_worker.rb
                 lib/mail_handler/parts.rb]
      files.each { |name| File.write(File.join(root, name), 'as loaded') }
      names = -> {
        [described_class.release(root),
         AlaveteliSandbox::RedactorStep.release(root),
         AlaveteliSandbox::MailStep.release(root, %w[/g/gems/mail-2.9.1/lib])]
      }

      taken = names.call
      files.each { |name| File.write(File.join(root, name), 'a new release') }

      expect(names.call).to eq(taken)
    end

    it 'are taken as a process of the app starts, when cells are ' \
       'configured' do
      sockets('/run/pdf.sock', '/run/office.sock', '/run/mail.sock')
      allow(Rails.logger).to receive(:warn)
      expect(described_class).to receive(:releases).and_call_original

      AlaveteliSandbox.boot

      expect(Rails.logger).to have_received(:warn).
        with(/\[sandbox\] mode=required .* cells=\h+ pdf=\h+ mail=\h+ /)
    end

    it 'are not taken without cells' do
      sockets('', '', '', mode: 'off')
      expect(described_class).not_to receive(:releases)
      allow(Rails.logger).to receive(:warn)

      AlaveteliSandbox.boot
    end
  end

  describe '.run' do
    it 'sends the step, the job, the limits and its release on one line' do
      cell_answers("#{header}\n")
      run

      expect(requests).to eq(
        [step.merge('job' => 'job-abc', 'release' => described_class.release,
                    'limits' => JSON.parse(JSON.generate(limits)))]
      )
    end

    it 'rebuilds a step that succeeded, with its output as bytes' do
      out = "\xFFtext".b
      cell_answers("#{header(stdout_size: 5, stderr_size: 4)}\n#{out}warn")
      result = run

      expect(result).to be_success
      expect(result.stdout).to eq(out)
      expect(result.stdout.encoding).to eq(Encoding::BINARY)
      expect(result.stderr).to eq('warn')
      expect(result.sandboxed).to be true
      expect(result).not_to be_sandbox_failed
    end

    it 'rebuilds a step that failed, was killed, or went over a limit' do
      cell_answers do |connection|
        connection.write(
          case requests.size
          when 1 then "#{header(exitstatus: 3, stderr_size: 3)}\nbad"
          when 2 then "#{header(exitstatus: nil, termsig: 9)}\n"
          else
            "#{header(exitstatus: nil, termsig: 9, timed_out: true,
                      stdout_overflow: true, outlived: true)}\n"
          end
        )
      end

      failed = run
      expect(failed).not_to be_success
      expect(failed.status_description).to eq('exit 3')
      expect(failed.stderr).to eq('bad')

      killed = run
      expect(killed.signal).to eq(9)
      expect(killed.status_description).to eq('signal 9')

      stopped = run
      expect(stopped.timed_out).to be true
      expect(stopped.stdout_overflow).to be true
      expect(stopped.outlived).to be true
    end

    it 'rebuilds a step whose sandbox never started' do
      cell_answers(
        "#{header(exitstatus: 1, info: '', namespace_unconfirmed: true)}\n"
      )
      expect(run).to be_sandbox_failed
    end
  end

  describe 'refusing a step' do
    def refused(message)
      raise_error(AlaveteliSandbox::Refused, message)
    end

    it 'refuses when its cell has no socket set' do
      allow(AlaveteliConfiguration).to receive(:sandbox_pdf_cell).and_return('')
      expect { run }.to refused(/no converter cell is set/)
    end

    it 'refuses a cell there isn’t' do
      expect { described_class.run(nil, step, job: 'job-a', limits: limits) }.
        to refused(/no converter cell is set/)
    end

    it 'refuses when the socket isn’t there' do
      expect { run }.to refused(/pdf converter cell is unavailable.*ENOENT/)
    end

    it 'refuses when nothing is listening' do
      UNIXServer.new(socket).close
      expect { run }.
        to refused(/pdf converter cell is unavailable.*ECONNREFUSED/)
    end

    it 'refuses when the cell refuses, saying why' do
      cell_answers("#{JSON.generate('error' => 'bad job name')}\n")
      expect { run }.to refused(/pdf converter cell refused.*bad job name/)
    end

    it 'refuses when the cell closes without answering' do
      cell_answers('')
      expect { run }.to refused(/unavailable: JSON::ParserError/)
    end

    it 'refuses an answer that isn’t the cell’s' do
      cell_answers("[1]\n")
      expect { run }.to refused(/unavailable.*not an object/)
    end

    it 'refuses an answer without the step’s sizes or with a wrong status' do
      cell_answers do |connection|
        wrong = "#{header(exitstatus: 'x')}\n"
        connection.write(requests.size == 1 ? "{}\n" : wrong)
      end
      expect { run }.to refused(/unavailable: TypeError/)
      expect { run }.to refused(/unavailable: ArgumentError/)
    end

    it 'refuses output that isn’t the size the answer says' do
      cell_answers("#{header(stdout_size: 10)}\nshort")
      expect { run }.to refused(/not the size it says/)
    end

    it 'refuses more output than the step’s limits allow' do
      limits[:stdout] = 10
      limits[:stderr] = 10
      stub_const("#{described_class}::HEADER_BYTES", 200)
      cell_answers("#{header(stdout_size: 400)}\n#{'x' * 400}")
      expect { run }.to refused(/too large/)
    end

    it 'refuses when the answer doesn’t come in time' do
      limits[:timeout] = 0
      stub_const("#{described_class}::GRACE", 0.2)
      cell_answers { |_connection| sleep 2 }
      expect { run }.to refused(/unavailable: IOError: no answer in time/)
    end
  end
end
