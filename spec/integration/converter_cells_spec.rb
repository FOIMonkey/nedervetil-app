require 'spec_helper'

# Cells run as the test user here, so separate UIDs aren't verified—only modes.
RSpec.describe 'Conversion steps in converter cells' do
  let(:dir) { Dir.mktmpdir('cells-spec') }
  let(:sockets) do
    { 'pdf' => File.join(dir, 'pdf.sock'),
      'office' => File.join(dir, 'office.sock'),
      'mail' => File.join(dir, 'mail.sock') }
  end
  let(:pids) { {} }

  before do
    allow(AlaveteliConfiguration).to receive_messages(
      sandbox_converters: 'required', sandbox_pdf_cell: sockets['pdf'],
      sandbox_office_cell: sockets['office'],
      sandbox_mail_cell: sockets['mail']
    )
  end

  after do
    pids.each_value { |pid| stop(pid) }
    FileUtils.remove_entry(dir)
  end

  # Cache each exited PID: waiting a second time while another starts raises.
  def start_cells(volume)
    sockets.each do |kind, socket|
      pids[kind] = Process.spawn(
        { 'SANDBOX_CELL_KIND' => kind, 'SANDBOX_CELL_SOCKET' => socket,
          'SANDBOX_VOLUME' => volume, 'PATH' => ENV.fetch('PATH'),
          'SANDBOX_BWRAP' => AlaveteliSandbox.bwrap },
        RbConfig.ruby, '--disable-gems',
        Rails.root.join('script/sandbox_cell.rb').to_s,
        unsetenv_others: true, err: "#{socket}.err"
      )
    end
    exited = {}
    Timeout.timeout(60) do
      sleep 0.05 until sockets.all? do |kind, socket|
        next true if File.socket?(socket)

        exited[kind] ||= Process.wait(pids[kind], Process::WNOHANG)
      end
    end
  end

  def said(kind)
    File.read("#{sockets[kind]}.err").strip
  end

  def need_pdf_cell
    return if File.socket?(sockets['pdf'])

    skip "the PDF cell won't serve here: #{said('pdf')}"
  end

  def stop(pid)
    Process.kill('TERM', pid)
    Process.wait(pid)
  rescue Errno::ESRCH, Errno::ECHILD
    nil
  end

  context 'on any volume' do
    let(:volume) { File.join(dir, 'volume') }

    before do
      Dir.mkdir(volume, 0o710)
      allow(AlaveteliConfiguration).
        to receive(:sandbox_volume).and_return(volume)
      allow(AlaveteliSandbox).to receive(:volume_problem).and_return(nil)
      allow(Rails.logger).to receive(:warn)
      start_cells(volume)
    end

    def refusal_of(cell, program, job: 'job-none')
      step = { 'run' => 'program', 'program' => program, 'args' => [] }
      limits = AlaveteliSandbox::Job::STEP_DEFAULTS
      AlaveteliSandbox::Cell.run(cell, step, job: job, limits: limits)
      nil
    rescue AlaveteliSandbox::Refused => e
      e.message
    end

    it 'gives a cell a socket only its user and the volume’s group can use' do
      socket = File.stat(sockets['office'])
      expect(socket.mode & 0o777).to eq(0o660)
      expect(socket.gid).to eq(File.stat(volume).gid)
    end

    it 'has the Office cell refuse the PDF cell’s programs' do
      %w[pdftotext magick].each do |program|
        expect(refusal_of('office', program)).
          to match(/#{program} is not one of this cell's programs/)
      end
    end

    it 'has the PDF cell refuse the Office and mail cells’ programs' do
      need_pdf_cell
      %w[soffice tnef msgconvert].each do |program|
        expect(refusal_of('pdf', program)).
          to match(/#{program} is not one of this cell's programs/)
      end
    end

    it 'has the mail cell refuse the PDF and Office cells’ programs' do
      %w[pdftotext magick soffice].each do |program|
        expect(refusal_of('mail', program)).
          to match(/#{program} is not one of this cell's programs/)
      end
    end

    it 'has the PDF cell serve only under the required ImageMagick policy' do
      if File.socket?(sockets['pdf'])
        skip 'the required policy is installed here'
      end

      expect(said('pdf')).
        to match(/sandbox cell \(pdf\): not serving: ImageMagick's policy/)
    end

    it 'has a cell refuse a job that isn’t on the volume' do
      expect(refusal_of('office', 'soffice', job: '../etc')).
        to match(/bad job name/)
    end

    it 'refuses a step whose cell has stopped, and never runs it here' do
      stop(pids['office'])
      expect(AlaveteliSandbox::ProcessRunner).not_to receive(:new)

      AlaveteliSandbox.job(input: 'x', input_name: 'input.doc') do |job|
        expect { job.run('soffice', '--headless', job.input) }.
          to raise_error(AlaveteliSandbox::Refused, /office converter cell/)
      end
    end
  end

  context 'where bubblewrap can run' do
    let(:volume) { AlaveteliSandbox.volume }
    let(:pdf) { file_fixture('interesting.pdf').binread }

    # The volume as it is with cells: its group may enter. Put back after.
    around do |example|
      mode = File.stat(volume).mode & 0o7777 if File.directory?(volume)
      File.chmod(0o710, volume) if mode && File.owned?(volume)
      example.run
    ensure
      File.chmod(mode, volume) if mode && File.owned?(volume)
    end

    before do
      problem = AlaveteliSandbox.volume_problem
      skip "the sandbox can't run here: #{problem}" if problem
      start_cells(volume)
      need_pdf_cell
      begin
        AlaveteliSandbox.self_test
      rescue AlaveteliSandbox::Error => e
        skip "the sandbox can't run here: #{e.message}"
      end
    end

    it 'runs a step in the PDF cell' do
      text = AlaveteliSandbox.job(input: pdf, input_name: 'input.pdf') do |job|
        job.run('pdftotext', '-enc', 'UTF-8', job.input, '-').stdout
      end
      expect(text).to include('thisisthebody')
    end

    it 'unpacks a winmail.dat in the mail cell' do
      mail = Mail.read(
        file_fixture_name('incoming-request-tnef-attachments.eml')
      )
      tnef = mail.all_parts.find do |part|
        part.mime_type == 'application/ms-tnef'
      end
      allow(AlaveteliSandbox::Cell).to receive(:run).and_call_original

      attachments = MailHandler.tnef_attachments(tnef.body.decoded)

      expect(attachments.map { |a| a[:filename] }).to be_present
      expect(AlaveteliSandbox::Cell).
        to have_received(:run).
        with('mail', anything, job: anything, limits: anything)
    end

    it 'converts an attached Outlook message in the mail cell' do
      allow(AlaveteliSandbox::Cell).to receive(:run).and_call_original

      expect { MailHandler.outlook_self_test }.not_to raise_error
      expect(AlaveteliSandbox::Cell).
        to have_received(:run).
        with('mail', hash_including('program' => 'msgconvert'),
             job: anything, limits: anything)
    end

    it 'runs one job’s steps in two cells: LibreOffice, then poppler' do
      type = 'application/vnd.openxmlformats-officedocument.' \
             'presentationml.presentation'
      text = AttachmentToText.from_string(
        file_fixture('interesting.pptx').binread, content_type: type
      ).to_text
      expect(text).to include('Interesting')
    end

    it 'lets a step read what the app wrote, and the app what a step wrote' do
      AlaveteliSandbox.job(input: pdf, input_name: 'input.pdf') do |job|
        File.binwrite(job.scratch('copy.pdf'), pdf)
        job.run('pdftoppm', '-r', '50', '-png', '-singlefile',
                job.scratch('copy.pdf'), job.scratch('page'))
        expect(job.read('page.png', max: 1_000_000)).to start_with("\x89PNG".b)
      end
    end

    it 'runs PDFRedactor’s worker in the PDF cell, with nothing parsed here' do
      expect(PDFRedactor::QdfDoc).not_to receive(:new)
      expect { PDFRedactor::Isolated.self_test }.not_to raise_error
      expect(PDFRedactor::Isolated.survey(pdf)).to be_an(Array)
    end

    it 'reports a program that fails, with its output' do
      AlaveteliSandbox.job(input: 'not a PDF', input_name: 'input.pdf') do |job|
        expect { job.run('pdfinfo', job.input) }.
          to raise_error(AlaveteliSandbox::Failed) { |error|
            expect(error.result.stderr).not_to be_empty
          }
      end
    end

    it 'leaves nothing on the volume' do
      AlaveteliSandbox.job(input: pdf, input_name: 'input.pdf') do |job|
        job.run('pdftoppm', '-r', '50', '-png', job.input, job.scratch('p'))
      end
      expect(Dir.children(volume).grep(/\Ajob-/)).to be_empty
    end
  end
end
