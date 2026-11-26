require 'spec_helper'
require 'open3'

# The worker expects tnef and msgconvert in /usr/bin (all it sees sandboxed).
RSpec.describe 'Reading mail in the mail worker' do
  include MailReadingComparison

  fixtures = Dir[Rails.root.join('spec/fixtures/files/*.eml')]

  def fixture(name)
    File.binread(Rails.root.join('spec/fixtures/files', name))
  end

  def more_mails
    utf7 = <<~MAIL
      From: a@example.com
      Subject: UTF-7
      Content-Type: text/plain; charset=utf-7

      Hi Mom -+Jjo--! A+ImIDkQ.
    MAIL
    { 'a part in UTF-7' => utf7.gsub("\n", "\r\n").b }
  end

  def warned_about
    fixture('tnef-attachment-empty.eml').
      sub(/\r?\n/, "\nquoted from the mail: yes\n".b)
  end

  def too_deep
    inner = "Content-Type: text/plain\r\n\r\ninner\r\n"
    (MailHandler::MAX_PART_DEPTH + 1).times do
      inner = "Content-Type: message/rfc822\r\n\r\n#{inner}"
    end
    "From: a@example.com\r\nSubject: nested\r\n#{inner}"
  end

  context 'on its own' do
    def run_worker(raw, stored: nil, tools: true, bodies: 'all',
                   gems: AlaveteliSandbox::MailStep.gem_directories)
      Dir.mktmpdir('mail-worker-spec') do |dir|
        scratch = File.join(dir, 'scratch')
        Dir.mkdir(scratch)
        arguments = [File.join(dir, 'mail.eml'), scratch, tools ? '1' : '0',
                     bodies]
        File.binwrite(arguments.first, raw)
        if stored
          arguments << File.join(scratch, 'stored')
          File.binwrite(arguments.last, stored)
        end
        environment = %w[RUBYOPT RUBYLIB GEM_HOME GEM_PATH BUNDLE_GEMFILE].
                      to_h { |name| [name, nil] }
        _out, errors, status = Open3.capture3(
          environment, RbConfig.ruby, '--disable-gems',
          *gems.flat_map { |gem| ['-I', gem] },
          Rails.root.join('script/mail_worker.rb').to_s, *arguments
        )
        yield status, errors, scratch
      end
    end

    def worker_reading(raw, stored: nil, wanted: :all)
      bodies = stored && wanted == :all ? 'none' : wanted.to_s
      wanted = :none if bodies == 'none'
      run_worker(raw, stored: stored,
                      bodies: bodies) do |status, errors, scratch|
        expect(status).to be_success, errors
        report = JSON.parse(File.read(File.join(scratch, 'report.json')))
        MailHandler::Reading.new(report, wanted,
                                 stored: !stored.nil?) do |name, _size|
          File.binread(File.join(scratch, name))
        end
      end
    end

    fixtures.each do |path|
      name = File.basename(path)

      it "gives what the walk in the app gives for #{name}" do
        raw = File.binread(path)
        expect_reading_to_equal_walk(worker_reading(raw), raw)
      end
    end

    it 'gives what the walk in the app gives for a part in UTF-7' do
      raw = more_mails.fetch('a part in UTF-7')
      expect(walked(raw)[:parts].first[:body]).to include('Hi Mom')
      expect_reading_to_equal_walk(worker_reading(raw), raw)
    end

    it 'writes nothing to stderr of what the mail gem warns of' do
      expect { Mail.from_source(warned_about).subject }.
        to output(/quoted from the mail/).to_stderr

      run_worker(warned_about) do |status, errors, _scratch|
        expect(status).to be_success
        expect(errors).to eq('')
      end
    end

    it 'says why it failed, and nothing else, on stderr' do
      run_worker(warned_about, tools: false) do |status, errors, scratch|
        expect(status).not_to be_success
        expect(errors).
          to eq("ReadRefused: tnef could not run: tnef: disabled\n")
        expect(Dir.children(scratch)).to be_empty
      end
    end

    it 'still reads a mail that needs no tool when told to run none' do
      raw = fixture('incoming-request-pdf-attachment.eml')
      run_worker(raw, tools: false) do |status, errors, scratch|
        expect(status).to be_success, errors
        expect(Dir.children(scratch)).to include('report.json', 'part-1')
      end
    end

    it 'reports a mail past the part limits, and does not fail' do
      reading = worker_reading(too_deep)
      expect(reading.too_complex).to eq(walked(too_deep).message)
      expect(reading.parts).to be_empty
    end

    it 'says why an attached file was left as it came' do
      reading = worker_reading(fixture('tnef-attachment-truncated.eml'))
      expect(reading.unexpanded).to contain_exactly(['tnef', /tnef failed/])
    end

    it 'finds the part a stored file is the original of, and leaves only ' \
       'that part’s bytes' do
      raw = fixture('incoming-request-two-same-name.eml')
      last = walked(raw)[:parts].last
      stored = "X-Added: yes\n\n#{last[:body].b}"

      reading = worker_reading(raw, stored: stored)
      expect(exactly(reading.matched)).to eq(exactly(last))
      expect(reading.parts.count(&:body)).to eq(1)

      run_worker(raw, stored: stored, bodies: 'none') do |_, _, scratch|
        expect(Dir.children(scratch)).
          to contain_exactly('report.json', 'stored',
                             "part-#{reading.parts.size - 1}")
      end
    end

    it 'finds the uuencoded block a stored file is the original of' do
      raw = fixture('simple-uuencoded-attachment.eml')
      block = walked(raw)[:blocks].flatten.first

      matched = worker_reading(raw, stored: block[:body]).matched
      expect(matched).to include(block.except(:filename))
      expect(matched[:filename]).to eq(block[:filename])
    end

    it 'leaves one part’s bytes when only that part is asked for' do
      raw = fixture('incoming-request-two-same-name.eml')
      parts = walked(raw)[:parts]
      digest = parts.last[:hexdigest]

      reading = worker_reading(raw, wanted: digest)
      expect(exactly(reading.part_with(digest).attributes)).
        to eq(exactly(parts.last))
      run_worker(raw, bodies: digest) do |_, _, scratch|
        expect(Dir.children(scratch)).
          to contain_exactly('report.json', "part-#{parts.size - 1}")
      end
    end

    it 'leaves no part’s bytes when none are asked for' do
      raw = fixture('incoming-request-two-same-name.eml')
      run_worker(raw, bodies: 'none') do |status, _, scratch|
        expect(status).to be_success
        expect(Dir.children(scratch)).to eq(['report.json'])
      end
    end

    it 'fails when asked for something that is no choice of parts' do
      run_worker(fixture('incoming-request-plain.eml'),
                 bodies: '../etc') do |status, errors, _|
        expect(status).not_to be_success
        expect(errors).to start_with('ArgumentError')
      end
    end

    it 'fails, saying so first, when it cannot load its code' do
      run_worker(fixture('incoming-request-plain.eml'),
                 gems: []) do |status, errors, scratch|
        expect(status).not_to be_success
        expect(errors).to start_with('NotLoaded: LoadError')
        expect(Dir.children(scratch)).to be_empty
      end
    end
  end

  context 'in bubblewrap' do
    before do
      allow(AlaveteliConfiguration).to receive(:sandbox_converters).
        and_return('required')
      problem = AlaveteliSandbox.volume_problem
      skip "the sandbox can't run here: #{problem}" if problem
      begin
        AlaveteliSandbox.self_test
      rescue AlaveteliSandbox::Error => e
        skip "the sandbox can't run here: #{e.message}"
      end
    end

    fixtures.each do |path|
      name = File.basename(path)

      it "gives what the walk in the app gives for #{name}, with nothing " \
         'read here' do
        raw = File.binread(path)
        expect(MailHandler::Report).not_to receive(:build)
        reading = MailHandler::Reading.of(raw)
        expect_reading_to_equal_walk(reading, raw)
      end
    end

    it 'gives what the walk in the app gives for a part in UTF-7, with ' \
       'nothing read here' do
      raw = more_mails.fetch('a part in UTF-7')
      expect(MailHandler::Report).not_to receive(:build)
      expect_reading_to_equal_walk(MailHandler::Reading.of(raw), raw)
    end

    it 'raises TooComplex for a mail past the part limits' do
      expect { MailHandler::Reading.of(too_deep) }.
        to raise_error(MailHandler::TooComplex, walked(too_deep).message)
    end

    context 'with converters switched off' do
      before do
        allow(AlaveteliConfiguration).
          to receive(:converters_disabled).and_return(true)
        allow(Rails.logger).to receive(:warn)
      end

      it 'still reads a mail that needs no tool' do
        raw = fixture('incoming-request-pdf-attachment.eml')
        expect(MailHandler::Reading.of(raw).parts.size).to eq(2)
      end

      it 'refuses the read of a mail that needs tnef, as the app does' do
        raw = fixture('incoming-request-tnef-attachments.eml')
        expect { MailHandler.get_attachment_attributes(Mail.from_source(raw)) }.
          to raise_error(MailHandler::ReadRefused, /tnef could not run/)
        expect { MailHandler::Reading.of(raw) }.to raise_error(
          MailHandler::ReadRefused,
          'the mail worker failed: ReadRefused: tnef could not run: ' \
          'tnef: disabled'
        )
      end
    end

    it 'finds the part a stored file is the original of' do
      raw = fixture('incoming-request-two-same-name.eml')
      stored = walked(raw)[:parts].last[:body].b
      matched = MailHandler::Reading.of(raw, stored: stored).matched
      expect(matched).to include(body: stored)
    end

    it 'hands back one part when only that is asked for' do
      raw = fixture('incoming-request-two-same-name.eml')
      last = walked(raw)[:parts].last
      reading = MailHandler::Reading.of(raw, part: last[:hexdigest])

      expect(exactly(reading.part_with(last[:hexdigest]).attributes)).
        to eq(exactly(last))
      expect(reading.parts.count(&:body)).to eq(1)
    end

    it 'passes its self-test, as the health check runs it' do
      expect(MailHandler::Report).not_to receive(:build)
      expect { MailHandler::Reading.self_test }.not_to raise_error
    end

    it 'refuses the read when the worker cannot load its code' do
      allow(AlaveteliSandbox::MailStep).
        to receive(:gem_directories).and_return([])
      allow(Rails.logger).to receive(:warn)

      expect { MailHandler::Reading.of(fixture('incoming-request-plain.eml')) }.
        to raise_error(MailHandler::ReadRefused, /NotLoaded/)
    end

    it 'leaves nothing on the volume' do
      MailHandler::Reading.of(fixture('incoming-request-plain.eml'))
      expect(Dir.children(AlaveteliSandbox.volume).grep(/\Ajob-/)).
        to be_empty
    end
  end

  context 'in a mail cell' do
    let(:dir) { Dir.mktmpdir('mail-cell-spec') }
    let(:socket) { File.join(dir, 'mail.sock') }
    let(:volume) { AlaveteliSandbox.volume }
    let(:pids) { [] }

    # The volume as it is with cells: its group may enter. Put back after.
    around do |example|
      mode = File.stat(volume).mode & 0o7777 if File.directory?(volume)
      File.chmod(0o710, volume) if mode && File.owned?(volume)
      example.run
    ensure
      File.chmod(mode, volume) if mode && File.owned?(volume)
    end

    before do
      allow(AlaveteliConfiguration).to receive_messages(
        sandbox_converters: 'required', sandbox_mail_cell: socket,
        sandbox_pdf_cell: File.join(dir, 'no-pdf.sock'),
        sandbox_office_cell: File.join(dir, 'no-office.sock')
      )
      problem = AlaveteliSandbox.volume_problem
      skip "the sandbox can't run here: #{problem}" if problem
    end

    after do
      pids.each do |pid|
        Process.kill('TERM', pid)
        Process.wait(pid)
      rescue Errno::ESRCH, Errno::ECHILD
        nil
      end
      FileUtils.remove_entry(dir)
    end

    def start_cell(root: Rails.root.to_s,
                   gems: AlaveteliSandbox::MailStep.gem_directories)
      pids << Process.spawn(
        { 'SANDBOX_CELL_KIND' => 'mail', 'SANDBOX_CELL_SOCKET' => socket,
          'SANDBOX_VOLUME' => volume, 'PATH' => ENV.fetch('PATH'),
          'SANDBOX_BWRAP' => AlaveteliSandbox.bwrap,
          'SANDBOX_MAIL_GEMS' => gems.join(':') },
        RbConfig.ruby, '--disable-gems',
        File.join(root, 'script/sandbox_cell.rb'),
        unsetenv_others: true, err: "#{socket}.err"
      )
      Timeout.timeout(60) { sleep 0.05 until File.socket?(socket) }
      AlaveteliSandbox.self_test(cell: 'mail')
    rescue AlaveteliSandbox::Error => e
      skip "the sandbox can't run here: #{e.message}"
    end

    it 'gives what the walk in the app gives for every fixture, with ' \
       'nothing read here' do
      start_cell
      expect(MailHandler::Report).not_to receive(:build)
      expect(AlaveteliSandbox::ProcessRunner).not_to receive(:new)

      mails = fixtures.to_h do |path|
        [File.basename(path), File.binread(path)]
      end
      readings = mails.merge(more_mails).to_h do |name, raw|
        [name, [MailHandler::Reading.of(raw), raw]]
      end

      # The walk here runs tnef and msgconvert through the cell too.
      differing = readings.reject do |_name, (reading, raw)|
        exactly(read(reading)) == exactly(walked(raw))
      end
      expect(differing.keys).to eq([])
    end

    it 'finds the part a stored file is the original of' do
      start_cell
      raw = fixture('incoming-request-two-same-name.eml')
      stored = walked(raw)[:parts].last[:body].b
      matched = MailHandler::Reading.of(raw, stored: stored).matched
      expect(matched).to include(body: stored)
    end

    it 'hands back one part when only that is asked for' do
      start_cell
      raw = fixture('incoming-request-two-same-name.eml')
      last = walked(raw)[:parts].last
      reading = MailHandler::Reading.of(raw, part: last[:hexdigest])

      expect(exactly(reading.part_with(last[:hexdigest]).attributes)).
        to eq(exactly(last))
      expect(reading.parts.count(&:body)).to eq(1)
    end

    it 'passes its self-test, as the health check runs it' do
      start_cell
      expect(MailHandler::Report).not_to receive(:build)
      expect { MailHandler::Reading.self_test }.not_to raise_error
    end

    it 'leaves nothing on the volume' do
      start_cell
      MailHandler::Reading.of(fixture('incoming-request-plain.eml'))
      expect(Dir.children(volume).grep(/\Ajob-/)).to be_empty
    end

    # The checkout is not under /tmp, where a step sees its own empty one.
    it 'reads from a checkout that holds only the sandbox and the worker' do
      root = Dir.mktmpdir('checkout', Rails.root.join('tmp'))
      shared = Dir.glob(AlaveteliSandbox::Cell::SHARED_CODE,
                        base: Rails.root.to_s)
      (shared + AlaveteliSandbox::MailStep::SOURCE).each do |name|
        next unless File.file?(Rails.root.join(name))

        FileUtils.mkdir_p(File.dirname(File.join(root, name)))
        FileUtils.cp(Rails.root.join(name), File.join(root, name))
      end
      start_cell(root: root)

      raw = fixture('incoming-request-pdf-attachment.eml')
      expect_reading_to_equal_walk(MailHandler::Reading.of(raw), raw)
    ensure
      FileUtils.remove_entry(root)
    end

    it 'refuses a read when the cell has not been told the gems' do
      start_cell(gems: [])
      allow(Rails.logger).to receive(:warn)

      expect { MailHandler::Reading.of(fixture('incoming-request-plain.eml')) }.
        to raise_error(MailHandler::ReadRefused, /not been told/)
    end

    it 'refuses a read when the cell’s gems are not the app’s' do
      gems = AlaveteliSandbox::MailStep.gem_directories
      start_cell(gems: gems + [File.join(dir, 'another-1.0')])
      allow(Rails.logger).to receive(:warn)

      expect { MailHandler::Reading.of(fixture('incoming-request-plain.eml')) }.
        to raise_error(MailHandler::ReadRefused, /differ; restart the cell/)
    end

    it 'refuses a read when the cell has stopped, and never reads here' do
      start_cell
      Process.kill('TERM', pids.first)
      Process.wait(pids.first)
      allow(Rails.logger).to receive(:warn)
      expect(MailHandler::Report).not_to receive(:build)

      expect { MailHandler::Reading.of(fixture('incoming-request-plain.eml')) }.
        to raise_error(MailHandler::ReadRefused, /mail converter cell/)
    end
  end
end
