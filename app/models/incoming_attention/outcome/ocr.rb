require 'tmpdir'

module IncomingAttention
  module Outcome
    # Local Tesseract OCR for scanned PDFs (first pages of the served masked
    # #body only; enabled via INCOMING_OUTCOME_OCR). Untrusted PDFs are
    # rasterized by pdftoppm and OCR'd inside bounded AlaveteliSandbox jobs.
    module Ocr
      PAGES = 2
      MAX_DOCUMENTS = 2
      # Pixels on the longer side (~300 dpi for A4).
      LONG_SIDE = 3_500
      SECONDS = 30
      MEMORY_BYTES = 512 * 1024 * 1024
      MAX_CHARS = 20_000

      module_function

      def enabled?
        AlaveteliConfiguration.incoming_outcome_ocr == true && available?
      end

      def available?
        %w[prlimit pdftoppm tesseract].all? { |program| path(program) }
      end

      # Resolves via core's UTILITY_SEARCH_PATH so PATH never picks binaries.
      def path(program)
        AlaveteliSandbox.program_path(program, sandboxed: false)
      rescue AlaveteliSandbox::Failed
        nil
      end

      def pdf_text(bytes)
        AlaveteliSandbox.job(input: bytes, input_name: 'input.pdf') do |job|
          rendered = limited('pdftoppm', '-cropbox', '-f', '1',
                             '-l', PAGES.to_s, '-scale-to', LONG_SIDE.to_s,
                             '-gray', '-png', job.input, job.scratch('page'),
                             job: job, binary_output: true)
          return nil unless rendered

          pages = job.files(/\Apage-\d+\.png\z/).first(PAGES)
          texts = pages.filter_map do |page|
            limited('tesseract', job.scratch(page), '-',
                    job: job, env: { 'OMP_THREAD_LIMIT' => '1' })
          end
          return nil if texts.empty?

          texts.join("\n\f").dup.force_encoding(Encoding::UTF_8).
            scrub('')[0, MAX_CHARS]
        end
      rescue StandardError => e
        Rails.logger.warn("request_outcome_ocr_failed #{e.class}")
        nil
      end

      # Runs inside an AlaveteliSandbox job when given, else under prlimit.
      def limited(program, *args, job:, binary_output: false, env: {})
        executable = path(program) or return nil
        if job
          out = job.run(program,
                        *args,
                        timeout: SECONDS,
                        memory: MEMORY_BYTES,
                        env: env).stdout
          return out if binary_output

          return out.force_encoding(Encoding.default_external)
        end

        AlaveteliExternalCommand.run(path('prlimit') || 'prlimit',
                                     "--as=#{MEMORY_BYTES}",
                                     "--cpu=#{SECONDS}",
                                     '--',
                                     executable,
                                     *args,
                                     timeout: SECONDS,
                                     binary_output: binary_output,
                                     env: env)
      rescue AlaveteliSandbox::Error
        nil
      end
    end
  end
end
