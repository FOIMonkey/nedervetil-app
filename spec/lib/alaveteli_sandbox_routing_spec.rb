require 'spec_helper'

# Verifies converter call-site job wiring with a pass-through bwrap stub
# (applies --setenv and execs unsandboxed; isolation needs real bwrap).
RSpec.describe 'Converters routed through AlaveteliSandbox' do
  let(:volume) { Dir.mktmpdir('sandbox-volume') }
  let(:bwrap) { File.join(Dir.tmpdir, "pass-bwrap-#{SecureRandom.hex(4)}") }

  before do
    allow(AlaveteliConfiguration).
      to receive(:sandbox_converters).and_return('required')
    allow(AlaveteliConfiguration).to receive(:sandbox_volume).and_return(volume)
    allow(AlaveteliConfiguration).to receive(:sandbox_bwrap).and_return(bwrap)
    allow(AlaveteliSandbox).to receive(:volume_problem).and_return(nil)
    allow(AlaveteliSandbox::ProcessRunner).
      to receive(:confirm_namespace?).and_return(false)
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

  def text_of(fixture, content_type)
    AttachmentToText.from_string(load_file_fixture(fixture),
                                 content_type: content_type).to_text
  end

  def unsandboxed_text_of(fixture, content_type)
    allow(AlaveteliConfiguration).
      to receive(:sandbox_converters).and_return('off')
    text_of(fixture, content_type)
  ensure
    allow(AlaveteliConfiguration).
      to receive(:sandbox_converters).and_return('required')
  end

  it 'never calls AlaveteliExternalCommand' do
    expect(AlaveteliExternalCommand).not_to receive(:new)
    text_of('interesting.pdf', 'application/pdf')
  end

  it 'extracts PDF text' do
    expect(text_of('interesting.pdf', 'application/pdf')).
      to match(/thisisthebody/)
  end

  it 'extracts HTML text, as it does unsandboxed' do
    text = text_of('interesting.html', 'text/html')
    expect(text).to match(/dull/)
    expect(text).to eq(unsandboxed_text_of('interesting.html', 'text/html'))
  end

  it 'extracts Word text as it does unsandboxed' do
    type = 'application/vnd.openxmlformats-officedocument.' \
           'wordprocessingml.document'
    expect(text_of('lorem.docx', type)).
      to eq(unsandboxed_text_of('lorem.docx', type))
  end

  it 'extracts Word text with LibreOffice' do
    type = 'application/vnd.openxmlformats-officedocument.' \
           'wordprocessingml.document'
    expect(text_of('lorem.docx', type)).to match(/Lorem ipsum/)
  end

  it 'extracts RTF text with LibreOffice' do
    expect(text_of('interesting.rtf', 'application/rtf')).
      to match(/thisisthebody/)
  end

  it 'extracts spreadsheet text with LibreOffice, sheet by sheet' do
    type = 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet'
    expect(text_of('interesting.xlsx', type)).to match(/=== .+ ===/)
  end

  it 'extracts presentation text with LibreOffice and pdftotext' do
    type = 'application/vnd.openxmlformats-officedocument.' \
           'presentationml.presentation'
    expect(text_of('interesting.pptx', type)).to match(/\S/)
  end

  it 'unpacks TNEF attachments' do
    mail = Mail.read(file_fixture_name('incoming-request-tnef-attachments.eml'))
    tnef = mail.all_parts.find do |part|
      part.mime_type == 'application/ms-tnef'
    end
    attachments = MailHandler.tnef_attachments(tnef.body.decoded)
    expect(attachments.map { |a| a[:filename] }).to be_present
    expect(attachments.first[:content]).to be_present
  end

  it 'treats a refused TNEF unpack as a failed parse, not an unreadable file' do
    allow(AlaveteliConfiguration).
      to receive(:converters_disabled).and_return(true)
    expect { MailHandler.tnef_attachments('not really tnef') }.
      to raise_error(MailHandler::ReadRefused, /could not run/)
  end

  it 'converts an attached Outlook message' do
    mail = Mail.read(file_fixture_name('incoming-request-oft-attachments.eml'))
    outlook = mail.all_parts.find { |part| MailHandler.is_outlook?(part) }

    converted = MailHandler.mail_from_outlook(outlook.body.decoded)

    expect(converted.subject).to eq('test')
    expect(converted.all_parts.map(&:mime_type)).
      to include('text/plain', 'application/octet-stream')
  end

  it 'treats a refused Outlook conversion as a failed parse, not an ' \
     'unreadable file' do
    allow(AlaveteliConfiguration).
      to receive(:converters_disabled).and_return(true)
    expect { MailHandler.outlook_as_mime('not really a message') }.
      to raise_error(MailHandler::ReadRefused, /could not run/)
  end

  it 'masks PDFs with qpdf' do
    rule = PDFRedactor::Rule.new(/foi@tfl\.gov\.uk/i, true, nil,
                                 'foi@tfl.gov.uk')
    masked, = PDFRedactor.redact(load_file_fixture('tfl.pdf'), [rule])
    expect(masked).to start_with('%PDF')
    expect(AttachmentToText.from_string(masked,
                                        content_type: 'application/pdf').
             to_text).not_to include('foi@tfl.gov.uk')
  end

  it 'reads a scanned PDF page and swaps it for a picture of itself' do
    tools = %w[pdftoppm tesseract magick].map do |program|
      system('which', program, out: File::NULL)
    end
    skip 'pdftoppm, tesseract or ImageMagick not installed' unless tools.all?
    scan = DocumentFixtures.scanned_pdf(lines: ['Dear Requester',
                                                'About Kingsfield School'])
    rule = PDFRedactor::Rule.new(PDFRedactor.tolerant('Kingsfield', false),
                                 true, nil, 'Kingsfield')
    masked, report = PDFRedactor.redact(scan, [rule], ocr: true)
    expect(masked).to start_with('%PDF')
    expect(report).to include('ocr_matches' => 1, 'pages_rasterized' => 1)
  end
end
