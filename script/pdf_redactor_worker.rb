# frozen_string_literal: true

# This script runs only inside the PDF redactor's bubblewrap namespace
# (PDFRedactor::Isolated). It has no Rails boot, database access,
# credentials or network. qpdf, fix-qdf, pdftotext and the OCR tools run in
# that same namespace, within the outer process limits.
# Where this worker says why it failed. Everything else written to stderr
# from here on is dropped so Ruby warnings cannot shift the first line.
SAID = $stderr.dup
$stderr.reopen(File::NULL) if $PROGRAM_NAME == __FILE__

# Only system tools are visible inside the worker.
ENV['PATH'] = '/usr/bin'
begin
  $LOAD_PATH.unshift(File.expand_path('../gems/pdf_redactor/lib', __dir__))
  require 'pdf_redactor'
rescue LoadError, StandardError => e
  SAID.puts "#{e.class}: #{e.message.to_s.lines.first.to_s[0, 160]}"
  exit 2
end

# mode: 'redact' masks the PDF; 'scan' reads it whole (FinalScan); 'cover'
# finds the first page where a picture keeps hidden pixels (PictureCover);
# 'survey' says what each page shows that its text may not (Survey).
# timeout: the app's Regexp.timeout in seconds, or 'none'.
begin
  mode, input, rules_path, output_path, report_path, ocr, depth, timeout = ARGV
  unless ARGV.size == 8 && %w[redact scan cover survey].include?(mode) &&
         %w[0 1].include?(ocr) && depth.match?(/\A[0-3]\z/) &&
         timeout.match?(/\A(?:none|\d+(?:\.\d+)?)\z/)
    raise PDFRedactor::Error, 'PDF worker arguments are invalid'
  end

  Regexp.timeout = timeout == 'none' ? nil : Float(timeout)
  rules = PDFRedactor::RuleCodec.load(File.binread(rules_path))
  pdf = File.binread(input)
  case mode
  when 'scan'
    PDFRedactor::FinalScan.check!(pdf, rules)
  when 'cover'
    page = PDFRedactor::PictureCover.first_page(pdf)
    File.binwrite(report_path, JSON.generate('first_page' => page))
  when 'survey'
    pages = PDFRedactor::Survey.pages(pdf)
    File.binwrite(report_path, JSON.generate('pages' => pages))
  else
    output, report = PDFRedactor.redact(pdf, rules, ocr: ocr == '1',
                                                    depth: depth.to_i)
    File.binwrite(output_path, output)
    File.binwrite(report_path, JSON.generate(report))
  end

rescue PDFRedactor::PasswordRequired
  SAID.puts 'PasswordRequired: PDF needs a password'
  exit 2
rescue StandardError, SystemStackError => e
  SAID.puts "#{e.class}: #{e.message.to_s.lines.first.to_s[0, 160]}"
  exit 2
end
