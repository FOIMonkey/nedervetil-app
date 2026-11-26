module AlaveteliSandbox
  ##
  # The step that runs PDFRedactor's worker (script/pdf_redactor_worker.rb):
  # its limits and its bubblewrap command. The app builds it here when it runs
  # the step itself, and so does the PDF cell, so both run the same thing.
  #
  # The worker can see only its PDF, the rule file, PDFRedactor's source and
  # the Ruby runtime.
  module RedactorStep
    # The cell that runs it when cells are configured.
    CELL = 'pdf'.freeze

    MODES = %w[redact scan cover survey].freeze

    # The worker and the code it loads.
    LIB = 'gems/pdf_redactor/lib'.freeze
    WORKER = 'script/pdf_redactor_worker.rb'.freeze
    SOURCE = [WORKER, "#{LIB}/**/*"].freeze

    # Whatever else the step was given. Memory is address space, for each
    # process.
    LIMITS = {
      timeout: 300,
      memory: 2 * 1024 * 1024 * 1024,
      processes: 256,
      stdout: 64 * 1024,
      stderr: 64 * 1024
    }.freeze

    module_function

    # Names the worker's code under root by its content. The PDF cell refuses
    # a step from an app whose worker differs from its own, so the two never
    # mask with different code.
    def release(root = Cell::ROOT)
      @release ||= {}
      @release[root] ||= Cell.digest(root, SOURCE)
    end

    # The directory Ruby is installed in, when a step can be given it: /usr
    # and /usr/local, which every step sees, or /opt/ruby-<version>, which is
    # bound for this one. nil for anywhere else.
    def runtime(ruby)
      dir = File.dirname(File.dirname(File.realpath(ruby)))
      return dir if ['/usr', '/usr/local'].include?(dir)

      dir if dir.match?(%r{\A/opt/ruby-[A-Za-z0-9.]+\z})
    end

    # Builds the same read-only worker mounts for the app and the cell.
    def command(bwrap:, input_dir:, scratch_dir:, input_name:, limits:,
                runtime:, ruby:, root:, mode:, ocr:, depth:, regexp_timeout:)
      limits = limits.merge(LIMITS)
      script = File.join(root, WORKER)
      mounts = [File.join(root, LIB), script]
      mounts << runtime if runtime.start_with?('/opt/')
      argv = Bubblewrap.argv(
        bwrap: bwrap, input_dir: input_dir, scratch_dir: scratch_dir,
        command: [ruby, '--disable-gems', script, mode,
                  File.join(input_dir, input_name),
                  File.join(scratch_dir, 'rules.json'),
                  File.join(scratch_dir, 'output.pdf'),
                  File.join(scratch_dir, 'report.json'),
                  ocr ? '1' : '0', depth.to_s,
                  regexp_timeout ? regexp_timeout.to_f.to_s : 'none'],
        limits: limits, read_only: mounts
      )
      [argv, limits]
    end
  end
end
