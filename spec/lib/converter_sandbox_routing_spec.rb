require 'spec_helper'

# A pass-through stand-in for bubblewrap applies the --setenv options and runs
# each step, unsandboxed. The isolation itself needs real bubblewrap.
RSpec.describe 'Converters routed through AlaveteliSandbox' do
  describe 'with the sandbox required' do
    let(:volume) { Dir.mktmpdir('sandbox-volume') }
    let(:bwrap) { File.join(Dir.tmpdir, "pass-bwrap-#{SecureRandom.hex(4)}") }

    before do
      allow(AlaveteliConfiguration).
        to receive(:sandbox_converters).and_return('required')
      allow(AlaveteliConfiguration).
        to receive(:sandbox_volume).and_return(volume)
      allow(AlaveteliConfiguration).to receive(:sandbox_bwrap).and_return(bwrap)
      allow(AlaveteliSandbox).to receive(:volume_problem).and_return(nil)
      allow(AlaveteliSandbox::ProcessRunner).
        to receive(:confirm_namespace?).and_return(false)
      allow(Rails.logger).to receive(:warn)
      File.write(bwrap, <<~SH)
        #!/bin/sh
        echo '{"child-pid": 1}' >&3
        head -c1 <&4 >/dev/null
        while [ $# -gt 0 ] && [ "$1" != "--" ]; do
          if [ "$1" = "--setenv" ]; then export "$2=$3"; shift 3; else shift; fi
        done
        shift
        mkdir -p "$HOME"
        exec "$@"
      SH
      File.chmod(0o755, bwrap)
    end

    after do
      FileUtils.remove_entry(volume)
      FileUtils.rm_f(bwrap)
    end

    it 'refuses a tool run outside a sandbox job' do
      expect(ExternalCommand).not_to receive(:new)
      expect do
        AttachmentManagement::Command.run('pdfinfo', '/dev/null', job: nil)
      end.to raise_error(AttachmentManagement::Command::Failed,
                         /refused outside a sandbox job/)
    end

    it 'refuses an engine without a job' do
      expect(ExternalCommand).not_to receive(:new)
      expect do
        AttachmentManagement.engine(job: nil).pdf_info('/dev/null')
      end.to raise_error(AttachmentManagement::Unsupported,
                         /refused outside a sandbox job/)
    end

    def sandboxed_programs
      programs = []
      allow(AlaveteliSandbox::Bubblewrap).
        to receive(:argv).and_wrap_original do |original, **options|
        programs << File.basename(options[:command].first)
        original.call(**options)
      end
      programs
    end

    it 'redacts a PDF: pdfinfo, pdftoppm, ImageMagick and pdftk as steps' do
      programs = sandboxed_programs
      pdf = AttachmentFixtures.pdf(
        pages: [
          AttachmentFixtures.letter_page(secret: 'Case officer: Jane Example')
        ]
      )
      out, report = AttachmentManagement.sandboxed(
        input: pdf,
        input_name: 'in.pdf'
      ) do |job|
        report = AttachmentManagement.engine(job: job).redact_pdf(
          job.input,
          { 1 => [AttachmentFixtures.letter_secret_box] },
          job.scratch('out.pdf')
        )
        [job.read('out.pdf', max: 64.megabytes), report]
      end
      expect(out).to start_with('%PDF')
      expect(report[:boxes_verified]).to eq(1)
      expect(report[:text_characters]).to eq(0)
      expect(programs.uniq).to include('pdfinfo', 'pdftoppm', 'magick', 'pdftk',
                                       'pdffonts', 'pdfimages', 'pdftotext')
    end

    it 'converts an Office file to PDF with LibreOffice as a step' do
      programs = sandboxed_programs
      docx = AttachmentFixtures.docx(paragraphs: ['A converted paragraph'])
      report = AttachmentManagement.sandboxed(
        input: docx,
        input_name: 'in.docx'
      ) do |job|
        AttachmentManagement.engine(job: job).
          convert_to_pdf(job.input, 'docx', job.scratch('out.pdf'))
      end
      expect(report[:pages]).to be >= 1
      expect(programs).to include('soffice')
    end

    it 'renders preview pages in a job and copies them out' do
      pdf = AttachmentFixtures.pdf(
        pages: [AttachmentFixtures.letter_page(secret: 'x'),
                AttachmentFixtures.letter_page(secret: 'y')]
      )
      previews = AttachmentManagement::Previews.new(
        attachment_id: 0,
        sha256: SecureRandom.hex(32),
        content_type: 'application/pdf'
      ) { pdf }
      expect(previews.page_count).to eq(2)
      png = previews.png(1)
      expect(File.binread(png, 8)).to eq("\x89PNG\r\n\x1A\n".b)
    ensure
      AttachmentManagement::Previews.clear(0)
    end

    it 'reads a scanned PDF with OCR in a job' do
      unless IncomingAttention::Outcome::Ocr.path('tesseract')
        skip 'Tesseract is not installed'
      end

      programs = sandboxed_programs
      pdf = AttachmentFixtures.pdf(
        pages: [AttachmentFixtures.letter_page(secret: 'SCANNEDWORDS',
                                               heading: 'HEADING')]
      )
      expect(IncomingAttention::Outcome::Ocr.pdf_text(pdf)).
        to include('SCANNEDWORDS')
      expect(programs).to eq(%w[pdftoppm tesseract])
    end

    it 'turns a sandbox refusal into the feature’s own failure' do
      allow(AlaveteliConfiguration).
        to receive(:converters_disabled).and_return(true)
      expect do
        AttachmentManagement.sandboxed(input: 'x') do |job|
          AttachmentManagement::Command.run('pdfinfo', job.input, job: job)
        end
      end.to raise_error(AttachmentManagement::Command::Failed, /disabled/)
    end
  end
end
