# frozen_string_literal: true

require 'json'

module PDFRedactor
  # Runs PDFRedactor's own parser on an untrusted PDF in a separate process,
  # in the sandbox's namespace (script/pdf_redactor_worker.rb), with time and
  # memory limits. qpdf, fix-qdf, pdftotext and the OCR tools it calls run in
  # that same namespace. This process only packs the rules and checks what
  # comes back. Used when the sandbox is required (AlaveteliSandbox.required?).
  module Isolated
    ToolError = AlaveteliSandbox::Error
    ToolFailed = AlaveteliSandbox::Failed
    REPORT_MAX_BYTES = 1024 * 1024

    module_function

    def required? = AlaveteliSandbox.required?
    def job(...) = AlaveteliSandbox.job(...)

    def program_path(name)
      AlaveteliSandbox.program_path(name, sandboxed: required?)
    end

    # [masked PDF, report], as PDFRedactor.redact. final_scan reads the
    # result whole in a second run of the worker.
    def redact(pdf, rules, ocr:, depth:, final_scan: false)
      raise Error, 'PDF attachment nesting limit exceeded' if depth > 3

      masked = run('redact', pdf, rules, ocr: ocr, depth: depth) do |job|
        # A separate qpdf process checks the worker's output before it is
        # accepted.
        job.run('qpdf', '--warning-exit-0', '--check',
                job.scratch('output.pdf'), stdout: 64 * 1024)
        output = job.read('output.pdf', max: MAX_BYTES)
        report = JSON.parse(job.read('report.json', max: REPORT_MAX_BYTES))
        unless output.start_with?('%PDF') && valid_report?(report, rules)
          raise Error, 'PDF redactor returned an invalid result'
        end

        [output, report]
      end
      final_scan(masked.first, rules) if final_scan
      masked
    end

    # As FinalScan.check!: returns, or raises Error.
    def final_scan(pdf, rules)
      run('scan', pdf, rules, ocr: false, depth: 0) { nil }
    end

    # As Survey.pages.
    def survey(pdf)
      run('survey', pdf, [], ocr: false, depth: 0) do |job|
        pages = JSON.parse(job.read('report.json', max: REPORT_MAX_BYTES)).
                fetch('pages')
        unless valid_survey?(pages)
          raise Error, 'page survey returned an invalid result'
        end

        pages
      end
    end

    # Runs the worker on a tiny PDF, with a rule it doesn't hold, as masking
    # would: bubblewrap, the conversion volume, the Ruby runtime, the worker
    # script, and qpdf and pdftotext inside it. Returns, or raises Error
    # saying why. For the health checks and sandbox:check.
    def self_test
      final_scan(tiny_pdf, [Rule.new(/Zebracorn/, true, nil, 'Zebracorn')])
    end

    # A one-page PDF with nothing on it, and its cross-reference table.
    def tiny_pdf
      objects = ['<< /Type /Catalog /Pages 2 0 R >>',
                 '<< /Type /Pages /Kids [3 0 R] /Count 1 >>',
                 '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 72 72] >>']
      pdf = +"%PDF-1.4\n"
      offsets = objects.each_with_index.map do |body, index|
        offset = pdf.bytesize
        pdf << "#{index + 1} 0 obj\n#{body}\nendobj\n"
        offset
      end
      xref = pdf.bytesize
      pdf << "xref\n0 #{objects.size + 1}\n0000000000 65535 f \n"
      offsets.each { |offset| pdf << format("%010d 00000 n \n", offset) }
      pdf << "trailer\n<< /Size #{objects.size + 1} /Root 1 0 R >>\n" \
             "startxref\n#{xref}\n%%EOF\n"
    end

    # As PictureCover.first_page: a page number, or nil.
    def picture_cover(pdf)
      run('cover', pdf, [], ocr: false, depth: 0) do |job|
        page = JSON.parse(job.read('report.json', max: REPORT_MAX_BYTES)).
               fetch('first_page')
        unless page.nil? || (page.is_a?(Integer) && page.positive?)
          raise Error, 'picture check returned an invalid result'
        end

        page
      end
    end

    # Any failure comes back as Error (or PasswordRequired), which callers
    # treat as a fault: a timeout, a limit, a crash, a result that's missing
    # or invalid, a full volume.
    def run(mode, pdf, rules, ocr:, depth:)
      AlaveteliSandbox.job(input: pdf, input_name: 'input.pdf',
                           output_bytes: 2 * MAX_BYTES) do |job|
        File.binwrite(job.scratch('rules.json'), RuleCodec.dump(rules))
        job.run_pdf_redactor(
          mode: mode, ocr: ocr, depth: depth,
          regexp_timeout: Regexp.timeout
        )
        yield job
      end
    rescue Error
      raise
    rescue AlaveteliSandbox::Failed => e
      message = e.result&.stderr.to_s.lines.first.to_s.strip
      raise PasswordRequired if message.start_with?('PasswordRequired:')
      # The worker names the error's class first.
      raise Matched, message[0, 200] if message.start_with?("#{Matched}:")

      raise Error, "PDF redactor failed: #{message[0, 200]}"
    rescue AlaveteliSandbox::Error => e
      # Why the sandbox refused or stopped it, for the admin mark.
      raise Error, "PDF redactor failed: #{e.class.name.split("::").last}: " \
                   "#{e.message[0, 200]}"
    rescue StandardError => e
      raise Error, "PDF redactor failed: #{e.class}"
    end

    def valid_survey?(pages)
      count_keys = %w[visible unmapped]
      pages.is_a?(Array) &&
        pages.each_with_index.all? do |page, index|
          page.is_a?(Hash) && page['number'] == index + 1 &&
            count_keys.all? do |key|
              page[key].is_a?(Integer) && !page[key].negative?
            end &&
            page['picture_share'].is_a?(Numeric) &&
            !page['picture_share'].negative?
        end
    end

    def valid_report?(report, rules)
      report.is_a?(Hash) && [true, false].include?(report['changed']) &&
        report['rules_matched'].is_a?(Array) &&
        report['rules_matched'].all? do |i|
          i.is_a?(Integer) && i >= 0 && i < rules.size
        end &&
        report['unmasked_parts'].is_a?(Array) &&
        report['unmasked_parts'].all?(String)
    end
  end
end
