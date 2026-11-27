# Runs external attachment converters in bounded jobs (AlaveteliSandbox::Job).
# With SANDBOX_CONVERTERS: required, every step runs in bubblewrap (no network,
# empty env, read-only /usr, fail-closed — never falls back unsandboxed). With
# converter cells set, steps run only in those services. See doc/FORK.md.
module AlaveteliSandbox
  Error = Class.new(StandardError)

  # The sandbox, the kill switch or the conversion volume stopped the step.
  # Nothing was run.
  Refused = Class.new(Error)

  # The step ran past its wall-clock timeout and was killed.
  TimedOut = Class.new(Error)

  # The step went over one of its own limits (output, file size, file count).
  LimitExceeded = Class.new(Error)

  # The program ran and exited unsuccessfully.
  class Failed < Error
    attr_reader :result

    def initialize(message, result = nil)
      super(message)
      @result = result
    end
  end

  # SANDBOX_CONVERTERS, or a setting that conflicts with it, is invalid.
  ConfigurationError = Class.new(Error)

  MODES = %w[off required].freeze

  # The only programs a step may run, under the converter cell that runs each
  # when cells are configured (AlaveteliSandbox::Cell). Core calls LibreOffice
  # as `libreoffice`, and the theme calls it as `soffice`. The mail cell runs
  # what only the reading of incoming mail uses.
  CELL_PROGRAMS = {
    'pdf' => %w[
      pdftotext pdftoppm pdfinfo pdffonts pdfimages pdfdetach
      pdftk qpdf fix-qdf magick tesseract elinks
    ].freeze,
    'office' => %w[soffice libreoffice].freeze,
    'mail' => %w[tnef msgconvert].freeze
  }.freeze

  PROGRAMS = CELL_PROGRAMS.values.flatten.freeze

  # Run by .self_test only.
  SELF_TEST_PROGRAM = 'true'.freeze

  # Names of files inside a job: no paths, no hidden files.
  SAFE_NAME = /\A[A-Za-z0-9][A-Za-z0-9._-]{0,127}\z/

  module_function

  def job(input: nil, input_name: 'input', **limits, &block)
    Job.open(input: input, input_name: input_name, limits: limits, &block)
  end

  # Runs /usr/bin/true as a step: in this process, or with cells configured
  # in each of them (or only the one named). Returns the last result, or
  # raises.
  def self_test(cell: nil)
    cells = Cell.configured? ? Array(cell || CELL_PROGRAMS.keys) : [nil]
    results = cells.map do |name|
      Job.open(self_test: true, cell: name) do |job|
        job.run(SELF_TEST_PROGRAM, timeout: 30)
      end
    end
    results.last
  end

  def cell_for(program)
    CELL_PROGRAMS.keys.find { |cell| CELL_PROGRAMS[cell].include?(program) }
  end

  def mode
    value = AlaveteliConfiguration.sandbox_converters.to_s.strip.downcase
    MODES.include?(value) ? value.to_sym : :invalid
  end

  def required?
    mode == :required
  end

  def disabled?
    AlaveteliConfiguration.converters_disabled == true
  end

  def volume
    AlaveteliConfiguration.sandbox_volume
  end

  def bwrap
    AlaveteliConfiguration.sandbox_bwrap
  end

  def check_configuration!
    if mode == :invalid
      raise ConfigurationError,
            "SANDBOX_CONVERTERS must be one of #{MODES.join(', ')} " \
            "(got #{AlaveteliConfiguration.sandbox_converters.inspect})"
    end
    if required? && RUBY_PLATFORM.include?('linux') && !Seccomp.supported?
      raise ConfigurationError,
            'SANDBOX_CONVERTERS=required needs seccomp support on this CPU'
    end

    problem = Cell.configuration_problem
    raise ConfigurationError, problem if problem
  end

  # Validates configuration and logs sandbox mode at boot. With cells, caches
  # shared code and worker release digests now so a restarted cell from another
  # release refuses this process until both are restarted.
  def boot
    check_configuration!

    if Cell.configured?
      release = Cell.releases.map { |name, digest| " #{name}=#{digest}" }.join
    end
    Rails.logger.warn(
      "[sandbox] mode=#{mode} disabled=#{disabled?}#{release} #{context}"
    )
  end

  # Returns nil when the conversion volume is a tmpfs ready for jobs, or a
  # description of what's wrong with it. Without cells it must be private to
  # this user. With cells it is shared with their users through its group,
  # and nobody else: mode 0710 lets them enter a job they are named, but not
  # list the jobs or create anything.
  def volume_problem
    mount = mounts.reverse.find { |m| m[:point] == volume }
    return "#{volume} is not mounted" unless mount

    type = mount[:type]
    return "#{volume} is #{type}, not tmpfs" unless type == 'tmpfs'

    missing = %w[nosuid nodev noexec] - mount[:options]
    return "#{volume} is mounted without #{missing.join(', ')}" if missing.any?

    stat = File.stat(volume)
    return "#{volume} isn't owned by this user" unless stat.uid == Process.euid

    return shared_volume_problem(stat) if Cell.configured?

    mode = format('%o', stat.mode & 0o777)
    return "#{volume} must be private (mode #{mode})" unless mode == '700'

    nil
  rescue SystemCallError => e
    "#{volume}: #{e.message}"
  end

  def shared_volume_problem(stat)
    mode = format('%o', stat.mode & 0o7777)
    unless mode == '710'
      return "#{volume} must be mode 710, for the cells' group only " \
             "(mode #{mode})"
    end
    return nil if (Process.groups | [Process.egid]).include?(stat.gid)

    "#{volume}'s group isn't one of this user's"
  end

  def mounts
    File.readlines('/proc/self/mountinfo').filter_map do |line|
      fields, rest = line.split(' - ', 2)
      next unless rest

      fields = fields.split(' ')
      type, _source, super_options = rest.split(' ')
      {
        point: unescape_mount_path(fields[4]),
        type: type,
        options: fields[5].split(',') + super_options.to_s.split(',')
      }
    end
  rescue SystemCallError
    []
  end

  def unescape_mount_path(path)
    path.gsub(/\\([0-7]{3})/) { Regexp.last_match(1).to_i(8).chr }
  end

  # Finds a program the same way AlaveteliExternalCommand does. When sandboxed,
  # it must resolve to a file under /usr, which is all a step can see.
  def program_path(name, sandboxed:, dirs: search_path)
    path = dirs.map { |dir| File.join(dir, name) }.find do |candidate|
      File.file?(candidate) && File.executable?(candidate)
    end
    unless path
      raise Failed, "#{name} is not installed (searched #{dirs.join(', ')})"
    end

    real = File.realpath(path)
    if sandboxed && !real.start_with?('/usr/')
      raise Refused, "#{name} resolves outside /usr (#{real})"
    end

    path
  end

  def search_path
    dirs = Array(AlaveteliConfiguration.utility_search_path)
    dirs.empty? ? ENV['PATH'].to_s.split(':') : dirs
  end

  # Logs why a step didn't succeed, with what asked for it, so the requests
  # affected by an outage can be found later.
  def log(reason, program, detail = nil)
    message = "[sandbox] #{reason} program=#{program} #{context}"
    message += " detail=#{detail.to_s.lines.first.to_s.strip[0, 300]}" if detail
    Rails.logger.warn(message)
  end

  # A page view can run a job inline (core masks with perform_now), and Rails
  # leaves that job in the context for the rest of the request, so both are
  # named, the page first.
  def context
    execution = ActiveSupport::ExecutionContext.to_h
    names = []
    if (controller = execution[:controller])
      names << "request=#{controller.request&.path}"
    end
    if (job = execution[:job])
      names << "job=#{job.class.name} job_id=#{job.job_id}"
    end
    return names.join(' ') if names.any?

    "process=#{File.basename($PROGRAM_NAME)} #{ARGV.first}".strip
  rescue StandardError
    'context=unknown'
  end
end
