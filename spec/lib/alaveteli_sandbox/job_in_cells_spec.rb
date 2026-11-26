require 'spec_helper'

# Stubbed converter-cell tests; see spec/integration/converter_cells_spec.rb.
RSpec.describe AlaveteliSandbox::Job, 'with converter cells' do
  let(:volume) { Dir.mktmpdir('sandbox-volume') }
  let(:outside) { Dir.mktmpdir('sandbox-outside') }
  let(:group) { File.stat(volume).gid }
  let(:ran) do
    AlaveteliSandbox::ProcessRunner::Result.new(
      status: AlaveteliSandbox::Cell::Status.new(0, nil), stdout: 'out'.b,
      stderr: ''.b, info: '{}', sandboxed: true
    )
  end
  let(:steps) { [] }

  before do
    allow(AlaveteliConfiguration).to receive_messages(
      sandbox_converters: 'required', sandbox_volume: volume,
      sandbox_pdf_cell: '/run/pdf/cell.sock',
      sandbox_office_cell: '/run/office/cell.sock',
      sandbox_mail_cell: '/run/mail/cell.sock'
    )
    allow(AlaveteliSandbox).to receive(:volume_problem).and_return(nil)
    allow(Rails.logger).to receive(:warn)
    allow(AlaveteliSandbox::Cell).to receive(:run) do |cell, step, **options|
      steps << [cell, step, options]
      ran
    end
    expect(AlaveteliSandbox::ProcessRunner).not_to receive(:new)
    expect(AlaveteliSandbox).not_to receive(:program_path)
  end

  after do
    FileUtils.remove_entry(volume)
    FileUtils.remove_entry(outside)
  end

  def mode(path)
    format('%o', File.lstat(path).mode & 0o7777)
  end

  # As the app's services run: nothing for the group unless it is given.
  around do |example|
    umask = File.umask(0o077)
    example.run
  ensure
    File.umask(umask)
  end

  describe 'a mail cell that takes a read and never answers' do
    let(:socket) { File.join(outside, 'mail.sock') }
    let(:server) { UNIXServer.new(socket) }
    let(:taken) { [] }

    before do
      allow(AlaveteliConfiguration).
        to receive(:sandbox_mail_cell).and_return(socket)
      allow(AlaveteliSandbox::Cell).to receive(:run).and_call_original
      stub_const('AlaveteliSandbox::Cell::GRACE', 1)
      stub_const('MailHandler::Reading::PAGE_SECONDS', 1)
      Current.reset
      @taker = Thread.new { loop { taken << server.accept } }
    end

    after do
      @taker.kill
      taken.each(&:close)
      server.close
      Current.reset
    end

    it 'keeps a page waiting for twice its seconds and the grace, once' do
      controller = instance_double(ApplicationController, request: nil)
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      Timeout.timeout(20) do
        ActiveSupport::ExecutionContext.set(controller: controller) do
          2.times do
            expect { MailHandler::Reading.of("Subject: x\r\n\r\nx") }.
              to raise_error(MailHandler::ReadRefused)
          end
        end
      end

      waited = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
      # Twice a second and a second's grace, with room for a busy machine.
      expect(waited).to be_between(3, 15)
      expect(taken.size).to eq(1)
    end
  end

  describe 'where steps run' do
    it 'sends each program to its own cell, as a name and arguments' do
      AlaveteliSandbox.job(input: 'x', input_name: 'input.pdf') do |job|
        expect(job.run('pdfinfo', job.input).stdout).to eq('out')
        job.run('soffice', '--headless', job.input)
        name = File.basename(File.dirname(job.scratch))

        expect(steps.map(&:first)).to eq(%w[pdf office])
        expect(steps[0][1]).to eq(
          'run' => 'program', 'program' => 'pdfinfo', 'args' => [job.input],
          'self_test' => false
        )
        expect(steps[0][2]).to match(
          job: name, limits: described_class::STEP_DEFAULTS
        )
        expect(steps[1][1]['args']).to eq(['--headless', job.input])
      end
    end

    it 'sends pdftk’s Java memory limit without sending JAVA_TOOL_OPTIONS' do
      AlaveteliSandbox.job { |job| job.run('pdftk', job.input, 'output', '-') }

      expect(steps[0][2][:limits]).to include(
        memory: described_class::JAVA_MEMORY,
        env: {}
      )
    end

    it 'sends PDFRedactor’s worker to the PDF cell, with the worker’s limits' do
      AlaveteliSandbox.job(input: 'x', input_name: 'input.pdf') do |job|
        job.run_pdf_redactor(
          mode: 'scan', ocr: false, depth: 1, regexp_timeout: 2
        )
      end

      cell, step, options = steps[0]
      expect(cell).to eq('pdf')
      expect(step).to eq('run' => 'pdf_redactor', 'mode' => 'scan',
                         'input_name' => 'input.pdf', 'ocr' => false,
                         'depth' => 1, 'regexp_timeout' => 2.0,
                         'worker' => AlaveteliSandbox::RedactorStep.release)
      expect(options[:limits]).
        to include(AlaveteliSandbox::RedactorStep::LIMITS)
    end

    it 'sends the mail worker to the mail cell, with the worker’s limits ' \
       'and the name of its code and gems' do
      AlaveteliSandbox.job(input: 'x', input_name: 'mail.eml') do |job|
        job.run_mail_read(bodies: 'all', stored: true)
      end

      cell, step, options = steps[0]
      expect(cell).to eq('mail')
      expect(step).to eq(
        'run' => 'mail_read', 'input_name' => 'mail.eml', 'tools' => true,
        'bodies' => 'all', 'stored' => true,
        'worker' => AlaveteliSandbox::MailStep.release(
          Rails.root.to_s, AlaveteliSandbox::MailStep.gem_directories
        )
      )
      expect(options[:limits]).to include(AlaveteliSandbox::MailStep::LIMITS)
    end

    it 'gives the mail worker less time when asked, and never more' do
      AlaveteliSandbox.job(input: 'x', input_name: 'mail.eml') do |job|
        job.run_mail_read(bodies: 'all', stored: false, timeout: 15)
        job.run_mail_read(bodies: 'all', stored: false, timeout: 900)
      end

      worker = AlaveteliSandbox::MailStep::LIMITS
      expect(steps.map { |step| step[2][:limits] }).to match(
        [include(worker.merge(timeout: 15)), include(worker)]
      )
    end

    it 'asks the mail worker only for all, none or one part’s bytes' do
      AlaveteliSandbox.job(input: 'x', input_name: 'mail.eml') do |job|
        expect { job.run_mail_read(bodies: '--help', stored: false) }.
          to raise_error(ArgumentError, /bodies/)
      end
      expect(steps).to be_empty
    end

    it 'still sends the mail worker with converters switched off, told to ' \
       'run no tools' do
      allow(AlaveteliConfiguration).
        to receive(:converters_disabled).and_return(true)

      AlaveteliSandbox.job(input: 'x', input_name: 'mail.eml') do |job|
        job.run_mail_read(bodies: 'none', stored: false)
        expect { job.run('tnef', job.input) }.
          to raise_error(AlaveteliSandbox::Refused, /disabled/)
      end

      expect(steps.size).to eq(1)
      expect(steps[0][1]).to include('run' => 'mail_read', 'tools' => false)
    end

    it 'sends the Office worker to the Office cell, with the worker’s ' \
       'limits and the name of its code and gems' do
      sheets = { max_rows: nil, max_columns: 60, max_cells: 10,
                 max_read_cells: 20 }
      AlaveteliSandbox.job(input: 'x', input_name: 'file.xlsx') do |job|
        job.run_office_read(sections: %w[guard sheets], sheets: sheets)
      end

      cell, step, options = steps[0]
      expect(cell).to eq('office')
      expect(step).to eq(
        'run' => 'office_read', 'input_name' => 'file.xlsx',
        'sections' => %w[guard sheets], 'sheets' => sheets,
        'worker' => AlaveteliSandbox::OfficeStep.release(
          Rails.root.to_s, AlaveteliSandbox::OfficeStep.gem_directories
        )
      )
      expect(options[:limits]).
        to include(AlaveteliSandbox::OfficeStep::LIMITS)
    end

    it 'sends zip_entries limits to the Office cell when asked' do
      zip = { max_entries: 500, max_entry: 1024, max_total: 4096 }
      AlaveteliSandbox.job(input: 'x', input_name: 'file.zip') do |job|
        job.run_office_read(sections: %w[guard zip_entries], zip: zip)
      end

      expect(steps[0][0]).to eq('office')
      expect(steps[0][1]).to include('run' => 'office_read',
                                     'sections' => %w[guard zip_entries],
                                     'zip' => zip)
    end

    it 'asks the Office worker only for its sections and sheet limits' do
      AlaveteliSandbox.job(input: 'x', input_name: 'file.xlsx') do |job|
        expect { job.run_office_read(sections: %w[--help]) }.
          to raise_error(ArgumentError, /sections/)
        expect do
          job.run_office_read(sections: %w[sheets],
                              sheets: { max_rows: 0, max_columns: 1,
                                        max_cells: 1, max_read_cells: 1 })
        end.to raise_error(ArgumentError, /max_rows/)
      end
      expect(steps).to be_empty
    end

    it 'still sends the Office worker with converters switched off' do
      allow(AlaveteliConfiguration).
        to receive(:converters_disabled).and_return(true)

      AlaveteliSandbox.job(input: 'x', input_name: 'file.docx') do |job|
        job.run_office_read(sections: %w[inspector])
      end

      expect(steps.size).to eq(1)
      expect(steps[0][1]).to include('run' => 'office_read')
    end

    it 'runs the self-test in each cell, or the one named' do
      AlaveteliSandbox.self_test
      AlaveteliSandbox.self_test(cell: 'office')

      expect(steps.map(&:first)).to eq(%w[pdf office mail office])
      expect(steps.map { |step| step[1] }).to all(
        include('program' => 'true', 'self_test' => true)
      )
    end

    it 'refuses the step when its cell does, and says so in the log' do
      allow(AlaveteliSandbox::Cell).to receive(:run).and_raise(
        AlaveteliSandbox::Refused, 'the pdf converter cell is unavailable'
      )
      expect(Rails.logger).to receive(:warn).
        with(/sandbox_unavailable program=pdfinfo.*cell is unavailable/)

      AlaveteliSandbox.job do |job|
        expect { job.run('pdfinfo', job.input) }.
          to raise_error(AlaveteliSandbox::Refused, /unavailable/)
      end
    end

    it 'still refuses a program on no list, without asking a cell' do
      AlaveteliSandbox.job do |job|
        expect { job.run('sh', '-c', 'id') }.
          to raise_error(AlaveteliSandbox::Refused, /not_allowed/)
      end
      expect(steps).to be_empty
    end

    it 'refuses every job when the sandbox isn’t required' do
      allow(AlaveteliConfiguration).
        to receive(:sandbox_converters).and_return('off')

      expect { AlaveteliSandbox.job { |job| job.run('pdfinfo', job.input) } }.
        to raise_error(AlaveteliSandbox::Refused, /cells_need_the_sandbox/)
      expect(steps).to be_empty
    end

    it 'checks what a cell’s step left, as it checks its own' do
      allow(AlaveteliSandbox::Cell).to receive(:run) do |*, job:, **|
        File.symlink('/etc/passwd', File.join(volume, job, 'scratch', 'out'))
        ran
      end

      AlaveteliSandbox.job do |job|
        expect { job.run('pdfinfo', job.input) }.
          to raise_error(AlaveteliSandbox::Failed, /unexpected link/)
      end
    end
  end

  describe 'sharing the job with the cells' do
    it 'gives the volume’s group the job and nobody else anything' do
      AlaveteliSandbox.job(input: 'x', input_name: 'input.pdf') do |job|
        dir = File.dirname(job.scratch)

        expect(mode(dir)).to eq('710')
        expect(mode(File.join(dir, 'in'))).to eq('750')
        expect(mode(job.input)).to eq('440')
        # Closed to the group until a step runs.
        expect(mode(job.scratch)).to eq('2700')
        expect(Dir.children(job.scratch)).to eq([])
        [dir, job.input, job.scratch].each do |path|
          expect(File.stat(path).gid).to eq(group)
        end
      end
    end

    it 'opens the scratch area to the group for a step, and only for it' do
      seen = nil
      allow(AlaveteliSandbox::Cell).to receive(:run) do |*, job:, **|
        scratch = File.join(volume, job, 'scratch')
        seen = ['', 'rules.json', 'converted', 'converted/sheet'].map do |name|
          mode(File.join(scratch, name))
        end
        ran
      end

      AlaveteliSandbox.job do |job|
        File.binwrite(job.scratch('rules.json'), '[]')
        FileUtils.mkdir_p(File.join(job.scratch, 'converted'))
        File.binwrite(File.join(job.scratch, 'converted', 'sheet'), 'x')
        expect(mode(job.scratch('rules.json'))).to eq('600')

        job.run('pdfinfo', job.input)

        expect(mode(job.scratch)).to eq('2700')
        expect(mode(File.join(job.scratch, 'converted'))).to eq('2700')
      end
      expect(seen).to eq(%w[2770 660 2770 660])
    end

    it 'closes the scratch area again when the cell refuses the step' do
      allow(AlaveteliSandbox::Cell).to receive(:run).
        and_raise(AlaveteliSandbox::Refused, 'the pdf converter cell is busy')

      AlaveteliSandbox.job do |job|
        expect { job.run('pdfinfo', job.input) }.
          to raise_error(AlaveteliSandbox::Refused)
        expect(mode(job.scratch)).to eq('2700')
      end
    end

    it 'fails a step that moved away a directory this process made' do
      allow(AlaveteliSandbox::Cell).to receive(:run) do |*, job:, **|
        scratch = File.join(volume, job, 'scratch')
        File.rename(File.join(scratch, 'converted'),
                    File.join(scratch, 'elsewhere'))
        ran
      end
      expect(Rails.logger).to receive(:warn).with(/unexpected_output/)

      AlaveteliSandbox.job do |job|
        FileUtils.mkdir_p(File.join(job.scratch, 'converted'))
        expect { job.run('soffice', '--outdir', 'converted', job.input) }.
          to raise_error(AlaveteliSandbox::Failed,
                         /directory in place of "converted"/)
      end
    end

    it 'audits everything under .libreoffice in scratch too' do
      allow(AlaveteliSandbox::Cell).to receive(:run) do |*, job:, **|
        profile = File.join(volume, job, 'scratch', '.libreoffice')
        Dir.mkdir(profile)
        File.symlink('/etc/passwd', File.join(profile, 'link'))
        ran
      end

      AlaveteliSandbox.job do |job|
        expect { job.run('soffice', '--headless', job.input) }.
          to raise_error(AlaveteliSandbox::Failed, /unexpected link/)
      end
    end

    it 'leaves what a link in the scratch area points to as it was' do
      target = File.join(outside, 'private')
      File.write(target, 'x')
      FileUtils.mkdir_p(File.join(outside, 'dir'))
      File.write(File.join(outside, 'dir', 'inner'), 'x')

      AlaveteliSandbox.job do |job|
        File.symlink(target, job.scratch('file'))
        File.symlink(File.join(outside, 'dir'), job.scratch('dir'))
        expect { job.run('pdfinfo', job.input) }.
          to raise_error(AlaveteliSandbox::Failed, /unexpected link/)
      end
      expect(mode(target)).to eq('600')
      expect(mode(File.join(outside, 'dir'))).to eq('700')
      expect(mode(File.join(outside, 'dir', 'inner'))).to eq('600')
    end
  end

  describe 'what a step may leave' do
    def cell_leaves
      allow(AlaveteliSandbox::Cell).to receive(:run) do |*, job:, **|
        yield File.join(volume, job, 'scratch')
        ran
      end
    end

    # Stubs lstat uid + 1 to simulate an entry owned by the cell user.
    def of_a_cell(path)
      theirs = Class.new(SimpleDelegator) { def uid = super + 1 }
      allow(File).to receive(:lstat).and_wrap_original do |original, name|
        stat = original.call(name)
        name == path ? theirs.new(stat) : stat
      end
    end

    it 'fails a step that left a directory of the cell’s' do
      cell_leaves do |scratch|
        Dir.mkdir(File.join(scratch, 'theirs'))
        of_a_cell(File.join(scratch, 'theirs'))
      end

      AlaveteliSandbox.job do |job|
        expect { job.run('pdfinfo', job.input) }.
          to raise_error(AlaveteliSandbox::Failed,
                         /directory of the cell's \(theirs\)/)
      end
    end

    it 'fails a step that leaves a directory of the cell’s under .libreoffice' do
      cell_leaves do |scratch|
        cache = File.join(scratch, '.libreoffice')
        Dir.mkdir(cache)
        of_a_cell(cache)
      end

      AlaveteliSandbox.job do |job|
        expect { job.run('soffice', '--headless', job.input) }.
          to raise_error(AlaveteliSandbox::Failed,
                         /directory of the cell's \(\.libreoffice\)/)
      end
    end

    it 'fails a step that left something that can’t be looked into' do
      skip 'root can read anything' if Process.euid.zero?
      closed = nil
      cell_leaves do |scratch|
        closed = File.join(scratch, 'closed')
        Dir.mkdir(closed, 0o000)
      end

      AlaveteliSandbox.job do |job|
        expect { job.run('pdfinfo', job.input) }.
          to raise_error(AlaveteliSandbox::Failed, /can't be read/)
        File.chmod(0o700, closed)
      end
    end
  end

  describe 'removing the job' do
    it 'gives the job a name that can’t be guessed' do
      AlaveteliSandbox.job do |job|
        expect(File.basename(File.dirname(job.scratch))).
          to match(/\Ajob-\h{32}\z/)
      end
    end

    it 'fails, and says so in the log, when the job can’t be removed' do
      allow(Dir).to receive(:rmdir).and_raise(Errno::EACCES)
      expect(Rails.logger).to receive(:warn).with(/job_not_removed/)

      expect { AlaveteliSandbox.job { nil } }.
        to raise_error(AlaveteliSandbox::Failed, /could not remove the job/)
      allow(Dir).to receive(:rmdir).and_call_original
    end

    it 'removes everything in it, and nothing a link points to' do
      kept = File.join(outside, 'kept')
      FileUtils.mkdir_p(kept)
      File.write(File.join(kept, 'file'), 'x')

      AlaveteliSandbox.job(input: 'x') do |job|
        nested = File.join(job.scratch, 'a', 'b')
        FileUtils.mkdir_p(nested)
        File.write(File.join(nested, 'c'), 'x')
        File.symlink(kept, File.join(job.scratch, 'a', 'link'))
        File.symlink(File.join(kept, 'file'), job.scratch('file'))
      end

      expect(Dir.children(volume)).to be_empty
      expect(File.read(File.join(kept, 'file'))).to eq('x')
    end

    it 'removes a job that was refused before it was made' do
      allow(AlaveteliSandbox).
        to receive(:volume_problem).and_return('not mounted')

      expect { AlaveteliSandbox.job { nil } }.
        to raise_error(AlaveteliSandbox::Refused, /not mounted/)
      expect(Dir.children(volume)).to be_empty
    end
  end
end
