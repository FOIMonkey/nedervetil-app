require 'spec_helper'
require 'open3'

RSpec.describe 'PDF redactor hardening' do
  # to_unicode: a ToUnicode CMap for the page's font, as object 6.
  def pdf_with_content(content, to_unicode: nil)
    stream = ->(body) do
      "<< /Length #{body.bytesize} >>\nstream\n#{body}\nendstream"
    end
    objects = [
      '<< /Type /Catalog /Pages 2 0 R >>',
      '<< /Type /Pages /Kids [3 0 R] /Count 1 >>',
      '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 595 842] ' \
        '/Resources << /Font << /F1 4 0 R >> >> /Contents 5 0 R >>',
      '<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica ' \
        "#{'/ToUnicode 6 0 R ' if to_unicode}>>",
      stream.call(content)
    ]
    objects << stream.call(to_unicode) if to_unicode
    pdf = +"%PDF-1.4\n".b
    offsets = objects.each_with_index.map do |body, i|
      offset = pdf.bytesize
      pdf << "#{i + 1} 0 obj\n#{body}\nendobj\n".b
      offset
    end
    xref = pdf.bytesize
    pdf << "xref\n0 #{objects.size + 1}\n0000000000 65535 f \n".b
    offsets.each { |offset| pdf << format("%010d 00000 n \n", offset).b }
    pdf << "trailer\n<< /Size #{objects.size + 1} /Root 1 0 R >>\n" \
           "startxref\n#{xref}\n%%EOF\n".b
  end

  it 'runs a full mask in the credential-free worker' do
    fixture = File.expand_path('../../fixtures/files/interesting.pdf', __dir__)
    worker = File.expand_path('../../../script/pdf_redactor_worker.rb', __dir__)
    rule = PDFRedactor::Rule.new(/thisisthebody/i, false)

    Dir.mktmpdir('pdf-hardening-') do |dir|
      rules = File.join(dir, 'rules.json')
      output = File.join(dir, 'output.pdf')
      report = File.join(dir, 'report.json')
      File.binwrite(rules, PDFRedactor::RuleCodec.dump([rule]))
      stdout, stderr, status = Open3.capture3(
        { 'HOME' => dir, 'TMPDIR' => dir }, RbConfig.ruby, worker,
        'redact', fixture, rules, output, report, '0', '0', '60',
        unsetenv_others: true
      )
      expect(status.success?).to be(true), "#{stdout} #{stderr}"
      expect(JSON.parse(File.binread(report))['rules_matched']).to include(0)
      check_out, check_err, checked = Open3.capture3(
        { 'HOME' => dir, 'TMPDIR' => dir }, '/usr/bin/qpdf', '--check', output,
        unsetenv_others: true
      )
      expect(checked.success?).to be(true), "#{check_out} #{check_err}"
      text, extract_err, extracted = Open3.capture3(
        { 'HOME' => dir, 'TMPDIR' => dir }, '/usr/bin/pdftotext', output, '-',
        unsetenv_others: true
      )
      expect(extracted.success?).to be(true), extract_err
      expect(text).not_to include('thisisthebody')
    end
  end

  it 'reports a password-protected PDF without writing a replacement' do
    fixture = File.expand_path('../../fixtures/files/interesting.pdf', __dir__)
    worker = File.expand_path('../../../script/pdf_redactor_worker.rb', __dir__)

    Dir.mktmpdir('pdf-hardening-') do |dir|
      locked = File.join(dir, 'locked.pdf')
      rules = File.join(dir, 'rules.json')
      output = File.join(dir, 'output.pdf')
      report = File.join(dir, 'report.json')
      _, encrypt_err, encrypted = Open3.capture3(
        { 'HOME' => dir, 'TMPDIR' => dir }, '/usr/bin/qpdf', '--encrypt',
        'synthetic-password', 'synthetic-owner', '256', '--', fixture, locked,
        unsetenv_others: true
      )
      expect(encrypted.success?).to be(true), encrypt_err
      File.binwrite(rules, PDFRedactor::RuleCodec.dump([]))
      _, stderr, status = Open3.capture3(
        { 'HOME' => dir, 'TMPDIR' => dir }, RbConfig.ruby, '--disable-gems',
        worker, 'redact', locked, rules, output, report, '0', '0', '60',
        unsetenv_others: true
      )
      expect(status.exitstatus).to eq(2)
      expect(stderr).to start_with('PasswordRequired:')
      expect(File.exist?(output)).to be(false)
    end
  end

  it 'keeps worker error classification on line 1 even when warnings occur' do
    worker = File.expand_path('../../../script/pdf_redactor_worker.rb', __dir__)
    rule = PDFRedactor::Rule.new(/Zebracorn/, true, nil, 'Zebracorn')
    Dir.mktmpdir('pdf-hardening-') do |dir|
      input = File.join(dir, 'in.pdf')
      rules = File.join(dir, 'rules.json')
      preload = File.join(dir, 'warn_first.rb')
      File.binwrite(input, pdf_with_content('BT /F1 12 Tf 72 700 Td ' \
                                            '(Zebracorn) Tj ET'))
      File.binwrite(rules, PDFRedactor::RuleCodec.dump([rule]))
      File.write(preload, <<~RUBY)
        tp = TracePoint.new(:end) do |event|
          next unless event.self.name == 'PDFRedactor::FinalScan'

          event.self.singleton_class.prepend(Module.new do
            def check!(*)
              warn 'noisy ruby warning during scan'
              super
            end
          end)
          tp.disable
        end
        tp.enable
      RUBY
      _, stderr, status = Open3.capture3(
        { 'HOME' => dir, 'TMPDIR' => dir }, RbConfig.ruby, '--disable-gems',
        '-r', preload, worker, 'scan', input, rules, File.join(dir, 'o.pdf'),
        File.join(dir, 'r.json'), '0', '0', '60', unsetenv_others: true
      )
      expect(status.exitstatus).to eq(2)
      expect(stderr.lines.first).to start_with('PDFRedactor::Matched:')
    end
  end

  it 'fails a deeply nested PDF in the worker with a bounded error' do
    worker = File.expand_path('../../../script/pdf_redactor_worker.rb', __dir__)

    Dir.mktmpdir('pdf-hardening-') do |dir|
      input = File.join(dir, 'nested.pdf')
      rules = File.join(dir, 'rules.json')
      output = File.join(dir, 'output.pdf')
      report = File.join(dir, 'report.json')
      File.binwrite(input, pdf_with_content(('[' * 129) + '0' + (']' * 129) +
                                            ' noop'))
      File.binwrite(rules, PDFRedactor::RuleCodec.dump([]))
      _, check_err, checked = Open3.capture3(
        { 'HOME' => dir, 'TMPDIR' => dir }, '/usr/bin/qpdf', '--check', input,
        unsetenv_others: true
      )
      expect(checked.success?).to be(true), check_err
      _, stderr, status = Open3.capture3(
        { 'HOME' => dir, 'TMPDIR' => dir }, RbConfig.ruby, worker,
        'redact', input, rules, output, report, '0', '0', '60',
        unsetenv_others: true
      )
      expect(status.exitstatus).to eq(2)
      expect(stderr).to include('PDF nesting limit exceeded')
      expect(File.exist?(output)).to be(false)
    end
  end

  it 'masks a PDF in the worker when its ToUnicode range counts through ' \
     'the surrogates' do
    worker = File.expand_path('../../../script/pdf_redactor_worker.rb', __dir__)
    rule = PDFRedactor::Rule.new(/Doelittle/, false)

    Dir.mktmpdir('pdf-hardening-') do |dir|
      input = File.join(dir, 'range.pdf')
      rules = File.join(dir, 'rules.json')
      output = File.join(dir, 'output.pdf')
      report = File.join(dir, 'report.json')
      File.binwrite(
        input,
        pdf_with_content('BT /F1 12 Tf 72 700 Td (Jane Doelittle attended.) ' \
                         'Tj ET',
                         to_unicode: '1 beginbfrange <0000> <FFFF> <00> ' \
                                     'endbfrange')
      )
      File.binwrite(rules, PDFRedactor::RuleCodec.dump([rule]))
      stdout, stderr, status = Open3.capture3(
        { 'HOME' => dir, 'TMPDIR' => dir }, RbConfig.ruby, worker,
        'redact', input, rules, output, report, '0', '0', '60',
        unsetenv_others: true
      )
      expect(status.success?).to be(true), "#{stdout} #{stderr}"
      expect(JSON.parse(File.binread(report))['rules_matched']).to eq([0])
      text, extract_err, extracted = Open3.capture3(
        { 'HOME' => dir, 'TMPDIR' => dir }, '/usr/bin/pdftotext', output, '-',
        unsetenv_others: true
      )
      expect(extracted.success?).to be(true), extract_err
      expect(text).to include('attended.')
      expect(text).not_to include('Doelittle')
    end
  end

  it 'checks the worker output in a separate qpdf step before accepting it' do
    Dir.mktmpdir('pdf-hardening-') do |dir|
      job = double('PDF job')
      allow(job).to receive(:scratch) { |name| File.join(dir, name) }
      allow(job).to receive(:run_pdf_redactor) do |**|
        File.binwrite(job.scratch('output.pdf'), '%PDF-1.4 result')
        File.binwrite(job.scratch('report.json'),
                      JSON.generate('changed' => false, 'rules_matched' => [],
                                    'unmasked_parts' => []))
      end
      expect(job).to receive(:run).
        with('qpdf', '--warning-exit-0', '--check',
             job.scratch('output.pdf'), stdout: 64 * 1024)
      allow(job).to receive(:read) { |name, **|
  File.binread(job.scratch(name))
}
      allow(AlaveteliSandbox).to receive(:job).and_yield(job)

      output, report = PDFRedactor::Isolated.redact('%PDF-1.4 input', [],
                                                    ocr: false, depth: 0)
      expect(output).to eq('%PDF-1.4 result')
      expect(report['rules_matched']).to eq([])
    end
  end

  # RuleCheck's reading of a PDF that would go public, in the same worker.
  it 'reads a PDF whole in the worker, failing on a rule that matches' do
    worker = File.expand_path('../../../script/pdf_redactor_worker.rb', __dir__)
    rule = PDFRedactor::Rule.new(/Zebracorn/, true, nil, 'Zebracorn')

    Dir.mktmpdir('pdf-hardening-') do |dir|
      rules = File.join(dir, 'rules.json')
      File.binwrite(rules, PDFRedactor::RuleCodec.dump([rule]))
      { 'Other words' => 0, 'Zebracorn' => 2 }.each do |text, exit|
        input = File.join(dir, 'in.pdf')
        content = "BT /F1 12 Tf 72 700 Td (#{text}) Tj ET"
        File.binwrite(input, pdf_with_content(content))
        _, stderr, status = Open3.capture3(
          { 'HOME' => dir, 'TMPDIR' => dir }, RbConfig.ruby, worker, 'scan',
          input, rules, File.join(dir, 'o.pdf'), File.join(dir, 'r.json'),
          '0', '0', '60', unsetenv_others: true
        )
        expect(status.exitstatus).to eq(exit), stderr
        expect(stderr).to include('still matches') if exit == 2
      end
    end
  end

  it 'checks a PDF’s pictures in the worker' do
    worker = File.expand_path('../../../script/pdf_redactor_worker.rb', __dir__)
    Dir.mktmpdir('pdf-hardening-') do |dir|
      input = File.join(dir, 'in.pdf')
      rules = File.join(dir, 'rules.json')
      report = File.join(dir, 'report.json')
      File.binwrite(input, pdf_with_content('BT /F1 12 Tf 72 700 Td (A) Tj ET'))
      File.binwrite(rules, PDFRedactor::RuleCodec.dump([]))
      _, stderr, status = Open3.capture3(
        { 'HOME' => dir, 'TMPDIR' => dir }, RbConfig.ruby, worker, 'cover',
        input, rules, File.join(dir, 'o.pdf'), report, '0', '0', '60',
        unsetenv_others: true
      )
      expect(status.success?).to be(true), stderr
      expect(JSON.parse(File.binread(report))).to eq('first_page' => nil)
    end
  end

  it 'surveys a PDF’s pages in the worker' do
    worker = File.expand_path('../../../script/pdf_redactor_worker.rb', __dir__)
    Dir.mktmpdir('pdf-hardening-') do |dir|
      input = File.join(dir, 'in.pdf')
      rules = File.join(dir, 'rules.json')
      report = File.join(dir, 'report.json')
      File.binwrite(input, pdf_with_content('BT /F1 12 Tf 72 700 Td (A) Tj ET'))
      File.binwrite(rules, PDFRedactor::RuleCodec.dump([]))
      _, stderr, status = Open3.capture3(
        { 'HOME' => dir, 'TMPDIR' => dir }, RbConfig.ruby, worker, 'survey',
        input, rules, File.join(dir, 'o.pdf'), report, '0', '0', '60',
        unsetenv_others: true
      )
      expect(status.success?).to be(true), stderr
      expect(JSON.parse(File.binread(report))).to eq(
        'pages' => [{ 'number' => 1, 'visible' => 1, 'unmapped' => 0,
                      'picture_share' => 0.0 }]
      )
    end
  end

  it 'refuses worker arguments it doesn’t know' do
    worker = File.expand_path('../../../script/pdf_redactor_worker.rb', __dir__)
    Dir.mktmpdir('pdf-hardening-') do |dir|
      [%w[eval 0], %w[scan soon]].each do |mode, timeout|
        _, stderr, status = Open3.capture3(
          { 'HOME' => dir, 'TMPDIR' => dir }, RbConfig.ruby, worker, mode,
          '/dev/null', '/dev/null', 'o', 'r', '0', '0', timeout,
          unsetenv_others: true
        )
        expect(status.exitstatus).to eq(2)
        expect(stderr).to include('arguments are invalid')
      end
    end
  end

  def stub_worker_job(dir)
    job = double('PDF job')
    allow(job).to receive(:scratch) { |name| File.join(dir, name) }
    allow(job).to receive(:run)
    allow(job).to receive(:read) { |name, **| File.binread(job.scratch(name)) }
    allow(AlaveteliSandbox).to receive(:job).and_yield(job)
    job
  end

  it 'gives the worker the app’s regexp timeout' do
    Dir.mktmpdir('pdf-hardening-') do |dir|
      job = stub_worker_job(dir)
      expect(job).to receive(:run_pdf_redactor).
        with(hash_including(regexp_timeout: Regexp.timeout))
      PDFRedactor::Isolated.final_scan('%PDF-1.4 input', [])
    end
  end

  it 'turns any failure around the worker into an error' do
    Dir.mktmpdir('pdf-hardening-') do |dir|
      job = stub_worker_job(dir)
      allow(job).to receive(:run_pdf_redactor) # writes no output.pdf

      expect do
        PDFRedactor::Isolated.redact('%PDF-1.4 input', [], ocr: false, depth: 0)
      end.to raise_error(PDFRedactor::Error, /failed: Errno::ENOENT/)
    end
  end

  it 'refuses a report that names a rule it wasn’t given' do
    Dir.mktmpdir('pdf-hardening-') do |dir|
      job = double('PDF job')
      allow(job).to receive(:scratch) { |name| File.join(dir, name) }
      allow(job).to receive(:run_pdf_redactor) do |**|
        File.binwrite(job.scratch('output.pdf'), '%PDF-1.4 result')
        File.binwrite(job.scratch('report.json'),
                      JSON.generate('changed' => true, 'rules_matched' => [3],
                                    'unmasked_parts' => []))
      end
      allow(job).to receive(:run)
      allow(job).to receive(:read) { |name, **|
  File.binread(job.scratch(name))
}
      allow(AlaveteliSandbox).to receive(:job).and_yield(job)

      expect do
        PDFRedactor::Isolated.redact('%PDF-1.4 input', [], ocr: false, depth: 0)
      end.to raise_error(PDFRedactor::Error, /invalid result/)
    end
  end

  it 'reads and rasterizes an invented scanned page in the worker' do
    tools = %w[qpdf pdftoppm tesseract magick].all? do |name|
      File.executable?("/usr/bin/#{name}")
    end
    skip 'OCR tools unavailable' unless tools

    worker = File.expand_path('../../../script/pdf_redactor_worker.rb', __dir__)
    rule = PDFRedactor::Rule.new(PDFRedactor.tolerant('secret', false),
                                 true, nil, 'secret')
    Dir.mktmpdir('pdf-hardening-') do |dir|
      input = File.join(dir, 'scan.pdf')
      rules = File.join(dir, 'rules.json')
      output = File.join(dir, 'output.pdf')
      report = File.join(dir, 'report.json')
      File.binwrite(input, DocumentFixtures.scanned_pdf(lines: ['Top secret']))
      File.binwrite(rules, PDFRedactor::RuleCodec.dump([rule]))
      _, stderr, status = Open3.capture3(
        { 'HOME' => dir, 'TMPDIR' => dir }, RbConfig.ruby, worker,
        'redact', input, rules, output, report, '1', '0', '60',
        unsetenv_others: true
      )
      expect(status.success?).to be(true), stderr
      result = JSON.parse(File.binread(report))
      expect(result).to include('ocr_matches' => 1, 'pages_rasterized' => 1)
      _, check_err, checked = Open3.capture3(
        { 'HOME' => dir, 'TMPDIR' => dir }, '/usr/bin/qpdf', '--check', output,
        unsetenv_others: true
      )
      expect(checked.success?).to be(true), check_err
    end
  end
end
