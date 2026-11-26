require 'spec_helper'
require 'tmpdir'

RSpec.describe IncomingAttention::Outcome::Ocr do
  def with_ocr(value)
    allow(AlaveteliConfiguration).
      to receive(:incoming_outcome_ocr).and_return(value)
    yield
  end

  # An image-only PDF: the text is rendered to pixels, so it has no text layer.
  def scanned_pdf(lines)
    Dir.mktmpdir do |dir|
      texts = lines.each_with_index.map { |text, i|
        { x: 60, y: 760 - (i * 30), text: text, size: 16 }
      }
      File.binwrite(File.join(dir, 'text.pdf'),
                    AttachmentFixtures.pdf(pages: [{ texts: texts }]))
      system('pdftoppm',
             '-r',
             '150',
             '-gray',
             '-png',
             '-singlefile',
             File.join(dir, 'text.pdf'),
             File.join(dir, 'scan'),
             exception: true)
      system('magick',
             File.join(dir, 'scan.png'),
             File.join(dir, 'scan.pdf'),
             exception: true)
      File.binread(File.join(dir, 'scan.pdf'))
    end
  end

  def tools?
    %w[prlimit pdftoppm tesseract magick].all? do |program|
      described_class.path(program)
    end
  end

  it 'is off unless switched on, and off when a program is missing' do
    with_ocr(nil) { expect(described_class.enabled?).to be false }
    with_ocr(true) do
      allow(described_class).to receive(:path).and_return('/usr/bin/x')
      expect(described_class.enabled?).to be true
      allow(described_class).to receive(:path).with('tesseract').and_return(nil)
      expect(described_class.enabled?).to be false
    end
  end

  def result(stdout)
    AlaveteliSandbox::ProcessRunner::Result.new(stdout: stdout.b)
  end

  def stub_steps(text: 'Recognised text', pages: 3)
    calls = []
    allow_any_instance_of(AlaveteliSandbox::Job).
      to receive(:run) do |job, program, *args, **options|
      calls << { job: job, program: program, args: args, options: options }
      if program == 'pdftoppm'
        prefix = args[args.index('-png') + 2]
        pages.times { |i| File.binwrite("#{prefix}-#{i + 1}.png", 'x') }
        result('')
      else
        result(text)
      end
    end
    calls
  end

  it 'runs fixed programs as sandbox steps, under memory, CPU and time limits, in a private job' do
    allow(described_class).to receive(:path) { |program| "/usr/bin/#{program}" }
    calls = stub_steps
    expect(described_class.pdf_text('%PDF-1.4 untrusted; rm -rf /')).
      to eq("Recognised text\n\fRecognised text")
    render, *pages = calls
    expect(render[:program]).to eq('pdftoppm')
    expect(render[:args]).to include('-f', '1', '-l', '2', '-scale-to', '3500')
    expect(render[:options]).to include(timeout: 30, memory: 536_870_912)
    expect(render[:args]).to include(render[:job].input)
    expect(File.basename(render[:job].input)).to eq('input.pdf')
    expect(pages.size).to eq(2)
    expect(pages.map { |call| call[:program] }).to eq(%w[tesseract tesseract])
    expect(pages.first[:options]).to include(timeout: 30, memory: 536_870_912,
                                             env: { 'OMP_THREAD_LIMIT' => '1' })
    expect(Dir.exist?(render[:job].scratch)).to be false
  end

  it 'gives nothing when rendering fails, and caps the text' do
    allow(described_class).to receive(:path) { |program| "/usr/bin/#{program}" }
    allow_any_instance_of(AlaveteliSandbox::Job).
      to receive(:run).and_raise(AlaveteliSandbox::Failed, 'exit 1')
    expect(described_class.pdf_text('not a pdf')).to be_nil
    stub_steps(text: 'é' * 30_000, pages: 1)
    expect(described_class.pdf_text('%PDF').length).
      to eq(described_class::MAX_CHARS)
  end

  it 'gives nothing when the sandbox refuses' do
    allow(described_class).to receive(:path) { |program| "/usr/bin/#{program}" }
    allow_any_instance_of(AlaveteliSandbox::Job).
      to receive(:run).and_raise(AlaveteliSandbox::Refused, 'disabled')
    expect(described_class.pdf_text('%PDF')).to be_nil
  end

  it 'logs which error stopped a reading, by its class' do
    allow(AlaveteliSandbox).to receive(:job).
      and_raise(NoMethodError, 'reply text')
    allow(Rails.logger).to receive(:warn).and_call_original
    expect(described_class.pdf_text('%PDF')).to be_nil
    expect(Rails.logger).to have_received(:warn).
      with('request_outcome_ocr_failed NoMethodError')
  end

  it 'reads a real scanned letter and returns nothing for a broken PDF' do
    unless tools?
      skip 'Tesseract, pdftoppm, prlimit or ImageMagick not installed'
    end
    text = described_class.pdf_text(
      scanned_pdf(['Dear Requester', 'We do not hold this information.'])
    )
    expect(text).to include('do not hold this information')
    expect(described_class.pdf_text("%PDF-1.4\n1 0 obj << /Type /Catalog >>")).
      to be_nil
  end

  describe 'reading a reply' do
    let(:request) {
      FactoryBot.create(:info_request, prominence: 'requester_only')
    }

    def receive_reply(files)
      mail = Mail.new do
        from 'officer@example.invalid'
        to 'request@example.invalid'
        message_id "#{SecureRandom.uuid}@example.invalid"
        subject 'Synthetic reply'
      end
      mail.content_type = 'multipart/mixed'
      main = Mail::Part.new
      main.content_type = 'text/plain; charset=UTF-8'
      main.body = 'Please see the attached response.'
      mail.add_part(main)
      files.each do |name, bytes|
        part = Mail::Part.new
        part.content_type = 'application/pdf'
        part.content_disposition = "attachment; filename=\"#{name}\""
        part.body = bytes
        mail.add_part(part)
      end
      request.send(:create_response!, mail)
    end

    it 'reads a scanned letter only with OCR on, through the masks, from the file the requester is served' do
      unless tools?
        skip 'Tesseract, pdftoppm, prlimit or ImageMagick not installed'
      end
      FactoryBot.create(:info_request_censor_rule, censorable: request,
                                                   text: 'Kingsfield',
                                                   replacement: '[redacted]')
      message = receive_reply(
        [['Response letter.pdf',
          scanned_pdf(['Dear Requester',
                       'Your request about Kingsfield School.',
                       'We do not hold this information.',
                       'Yours sincerely'])]]
      )
      off = with_ocr(nil) { IncomingAttention::Outcome::Input.build(message) }
      expect(off.request['documents']).to be_empty
      expect(off.signals).
        to include('omitted' => { 'Response letter.pdf' => 'no_text' },
                   'ocr' => 0)
      expect_any_instance_of(FoiAttachment).not_to receive(:unmasked_body)
      on = with_ocr(true) { IncomingAttention::Outcome::Input.build(message.reload) }
      text = on.request['documents'].map { |doc| doc['text'] }.join
      # Masking boxed the name in the scan itself, so OCR never reads it.
      expect(text).to include('do not hold this information')
      expect(text).not_to include('Kingsfield')
      expect(on.signals).to include('ocr' => 1, 'omitted' => {})
    end

    it 'reads at most two scanned documents for one reply' do
      allow(IncomingAttention::Outcome::Ocr).
        to receive(:enabled?).and_return(true)
      allow(IncomingAttention::Outcome::Ocr).
        to receive(:pdf_text).and_return('Recognised letter text ' * 10)
      blank = AttachmentFixtures.pdf(pages: [{ texts: [] }])
      message = receive_reply([['one.pdf', blank],
                               ['two.pdf', blank + ' '],
                               ['three.pdf', blank + '  ']])
      built = IncomingAttention::Outcome::Input.build(message)
      expect(IncomingAttention::Outcome::Ocr).to have_received(:pdf_text).twice
      expect(built.signals['ocr']).to eq(2)
      expect(built.signals['omitted']).to eq('three.pdf' => 'no_text')
    end

    it 'rejects OCR text when its source changes before OCR returns' do
      allow(described_class).to receive(:enabled?).and_return(true)
      blank = AttachmentFixtures.pdf(pages: [{ texts: [] }])
      message = receive_reply([['Response.pdf', blank]])
      allow(described_class).to receive(:pdf_text) do
        message.foi_attachments.find_by!(filename: 'Response.pdf').
          update_columns(masked_at: Time.current,
                         updated_at: Time.current + 1)
        'Synthetic recognised text ' * 10
      end

      built = IncomingAttention::Outcome::Input.build(message)
      expect(built.signals['ocr']).to eq(1)
      expect { IncomingAttention::Outcome::Input.recheck!(message, built) }.
        to raise_error(IncomingAttention::Input::Unavailable) { |error| expect(error.code).to eq('source_changed') }
    end

    it 'counts failed readings towards the two' do
      allow(IncomingAttention::Outcome::Ocr).
        to receive(:enabled?).and_return(true)
      allow(IncomingAttention::Outcome::Ocr).
        to receive(:pdf_text).and_return(nil)
      blank = AttachmentFixtures.pdf(pages: [{ texts: [] }])
      message = receive_reply([['one.pdf', blank],
                               ['two.pdf', blank + ' '],
                               ['three.pdf', blank + '  ']])
      built = IncomingAttention::Outcome::Input.build(message)
      expect(IncomingAttention::Outcome::Ocr).to have_received(:pdf_text).twice
      expect(built.signals['ocr']).to eq(0)
      expect(built.signals['omitted']).
        to eq('one.pdf' => 'no_text',
              'two.pdf' => 'no_text',
              'three.pdf' => 'no_text')
    end
  end
end
