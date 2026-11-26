module AlaveteliSandbox
  # Converter cell daemon (started by script/sandbox_cell.rb; app client is
  # AlaveteliSandbox::Cell). Runs without Rails, gems, credentials, or network.
  # Validates each UNIX-socket request against peer UID, release digest, kind
  # allowlist, and limit caps, then builds and runs the bubblewrap step itself.
  # ImageMagick cells verify ImagePolicy before serving. See doc/FORK.md.
  class CellServer
    JOB_NAME = /\Ajob-[A-Za-z0-9_-]{1,100}\z/
    # Only explicitly allowed per-program environment variables and values may
    # cross the cell socket boundary.
    PROGRAM_ENV = {
      'elinks' => { 'LANG' => /\A(C|C\.UTF-8)\z/ }.freeze,
      'tesseract' => { 'OMP_THREAD_LIMIT' => /\A[1-9]\d?\z/ }.freeze
    }.freeze

    # The most a step may ask for of each limit. A step must send them all.
    # None is below what the app's own callers ask for (the largest stdout is
    # a whole PDF's, PDFRedactor::MAX_BYTES), or a step would be cut short in
    # a cell that runs to the end in the app.
    MOST = {
      timeout: 600,
      memory: 4 * 1024 * 1024 * 1024,
      file_size: 1024 * 1024 * 1024,
      open_files: 1024,
      processes: 512,
      stdout: 256 * 1024 * 1024,
      stderr: 64 * 1024,
      tmp_size: 1024 * 1024 * 1024
    }.freeze

    CELL_PROCESSES = {
      'pdf' => 512,
      'office' => 512,
      'mail' => 128
    }.freeze

    REQUEST_BYTES = 1024 * 1024
    REQUEST_SECONDS = 5

    # Connections that may wait for a slot, beyond those running a step.
    WAITING = 16

    # What a step leaves in the scratch area is the app's to read and remove.
    UMASK = 0o007

    Refusal = Class.new(StandardError)

    # kind: which of CELL_PROGRAMS this cell runs. slots: steps it runs at
    # once. root: the checkout holding the workers and the code they load.
    # gems: for the mail and Office cells, the directories of the gems their
    # worker loads (MailStep.gem_directories, as script/mail_worker_gems
    # prints them, or OfficeStep's, as script/office_worker_gems does).
    def initialize(kind:, socket:, volume:, bwrap:, slots:, root:, gems: [])
      unless CELL_PROGRAMS.key?(kind)
        raise ArgumentError, "unknown kind of cell #{kind.inspect} " \
                             "(#{CELL_PROGRAMS.keys.join(' or ')})"
      end
      raise ArgumentError, 'a cell needs at least one slot' if slots < 1

      @kind = kind
      @socket = socket
      @volume = volume
      @bwrap = bwrap
      @slots = slots
      @root = root
      @gems = gems
    end

    def serve
      File.umask(UMASK)
      problem = image_policy_problem
      abort "#{name}: not serving: #{problem}" if problem

      File.unlink(@socket) if File.socket?(@socket)
      server = UNIXServer.new(@socket)
      # For the volume's group, which the app is in, whatever this user's own
      # group is.
      File.chown(nil, File.stat(@volume).gid, @socket)
      File.chmod(0o660, @socket)
      warn "#{name}: listening on #{@socket}, #{@slots} steps at once, " \
           "volume #{@volume}, release #{Cell.release(@root)}" \
           "#{", worker #{worker_release}" if worker_release}"
      handlers = []
      loop do
        reap(handlers)
        next unless server.wait_readable(1)

        connection = server.accept
        if handlers.size >= @slots + WAITING
          connection.wait_readable(0.1)
          refuse(connection, 'busy: too many steps are waiting')
        else
          handler = start_handler(server, connection)
          handlers << handler if handler
        end
        connection.close
      end
    end

    def handle(connection)
      check_peer(connection)
      request = JSON.parse(read_line(connection))
      raise Refusal, 'the request is not an object' unless request.is_a?(Hash)

      unless request['release'] == Cell.release(@root)
        raise Refusal, 'the app and this cell are from different releases; ' \
                       'restart the cell'
      end

      argv, limits, files = command(request)
      slot = take_slot(limits[:timeout])
      unless slot
        raise Refusal, "busy: all #{@slots} slots were in use for " \
                       "#{limits[:timeout]} seconds"
      end
      # The app gave up while this waited: its job is gone or going.
      return if connection.wait_readable(0)

      scratch = scratch_dir(request)
      result = run(argv, scratch, limits, files: files || {})
      release_to_app(scratch)
      answer(connection, result)
    rescue Refusal, JSON::ParserError, KeyError, TypeError,
           ArgumentError => e
      refuse(connection, e.message)
    rescue SystemCallError => e
      refuse(connection, "sandbox could not start: #{e.message}")
    ensure
      slot&.close
    end

    # Why this cell must not run ImageMagick, or nil: it asks ImageMagick,
    # in the sandbox a step gets, for the policy in force (ImagePolicy). nil
    # too for a cell that doesn't run ImageMagick.
    def image_policy_problem
      program = ImagePolicy::PROGRAM
      return unless CELL_PROGRAMS.fetch(@kind).include?(program)

      Dir.mktmpdir('policy-check') do |dir|
        limits = MOST.merge(timeout: 30, env: {})
        argv = Bubblewrap.argv(
          bwrap: @bwrap, input_dir: dir, scratch_dir: dir, limits: limits,
          command: [program_path(program, self_test: false), '-list', 'policy']
        )
        result = run(argv, dir, limits)
        next ImagePolicy.problem(result.stdout) if result.success?

        reason = result.stderr.lines.first.to_s.strip[0, 200]
        reason = result.status_description if reason.empty?
        reason = 'timed out' if result.timed_out
        "ImageMagick's policy could not be read: #{reason}"
      end
    rescue Refusal, SystemCallError => e
      "ImageMagick's policy could not be read: #{e.message}"
    end

    private

    def name
      "sandbox cell (#{@kind})"
    end

    # A process for each step, so one step's handling shares nothing with
    # the next. Returns its process ID, or nil, refusing the step, when this
    # cell has no room for another process.
    def start_handler(server, connection)
      fork do
        server.close
        handle(connection)
      end
    rescue SystemCallError => e
      refuse(connection, "busy: no room for another step (#{e.message})")
      nil
    end

    # Collects every child that has exited: the handlers, and any process a
    # step orphaned, which is handed to this one when it is the first process
    # in a container. Uncollected, they would use up the cell's processes.
    def reap(handlers)
      while (pid = Process.wait(-1, Process::WNOHANG))
        handlers.delete(pid)
      end
    rescue Errno::ECHILD
      nil # no children
    end

    # The app's user owns the volume. Nobody else may ask for a step, and a
    # job must be a directory of that user's.
    def app_uid
      File.stat(@volume).uid
    end

    # Before anything is read from the connection, so nobody else can hold a
    # handler by sending part of a request.
    def check_peer(connection)
      _pid, uid, _gid = connection.getsockopt(:SOCKET, :PEERCRED).unpack('iI2')
      raise Refusal, 'not the app’s user' unless uid == app_uid
    end

    # The request's line, which must all arrive within REQUEST_SECONDS and be
    # no more than REQUEST_BYTES.
    def read_line(connection)
      stop = monotonic + REQUEST_SECONDS
      line = +''
      until line.end_with?("\n")
        remaining = stop - monotonic
        unless remaining.positive? && connection.wait_readable(remaining)
          raise Refusal, 'no request was sent'
        end

        chunk = connection.read_nonblock(REQUEST_BYTES, exception: false)
        break if chunk.nil?
        next if chunk == :wait_readable

        line << chunk
        next unless line.bytesize > REQUEST_BYTES

        raise Refusal, 'the request is too long'
      end
      line
    end

    # Leaves the app able to read, check and remove everything in the scratch
    # area that is this cell's, whatever modes the step gave it: a converter
    # can make a directory or a file closed to the group, and the app's user
    # could then neither look into it nor remove the job. Called once nothing
    # of the step is running. Only this user's own entries can be changed, so
    # a link put in the way gains nothing.
    def release_to_app(scratch)
      Find.find(scratch) do |path|
        stat = File.lstat(path)
        next unless stat.uid == Process.euid

        if stat.directory?
          File.chmod(0o2770, path)
        elsif stat.file?
          File.chmod(0o660, path)
        end
      rescue SystemCallError
        next
      end
    end

    def run(argv, scratch, limits, files: {})
      ProcessRunner.new(
        argv, chdir: scratch, sandboxed: true, env: {}, clear_env: true,
              timeout: limits[:timeout], stdout_limit: limits[:stdout],
              stderr_limit: limits[:stderr], files: files
      ).run
    end

    def answer(connection, result)
      status = result.status
      header = {
        'exitstatus' => status&.exitstatus, 'termsig' => status&.termsig,
        'info' => result.info.to_s[0, 4096],
        'timed_out' => result.timed_out ? true : false,
        'stdout_overflow' => result.stdout_overflow ? true : false,
        'namespace_unconfirmed' => result.namespace_unconfirmed ? true : false,
        'outlived' => result.outlived ? true : false,
        'stdout_size' => result.stdout.bytesize,
        'stderr_size' => result.stderr.bytesize
      }
      connection.write("#{JSON.generate(header)}\n", result.stdout,
                       result.stderr)
    rescue Errno::EPIPE, Errno::ECONNRESET
      nil # the app has gone
    end

    def refuse(connection, reason)
      warn "#{name}: refused: #{reason}"
      connection.read_nonblock(REQUEST_BYTES, exception: false)
      connection.write("#{JSON.generate('error' => reason[0, 300])}\n")
    rescue Errno::EPIPE, Errno::ECONNRESET
      nil # the app has gone
    end

    # Holds one of the cell's slots, waiting up to seconds for one. Returns
    # the lock, which is released when it is closed or this process ends, or
    # nil if none came free.
    def take_slot(seconds)
      stop = monotonic + seconds
      loop do
        @slots.times do |number|
          file = File.open("#{@socket}.slot#{number}",
                           File::RDWR | File::CREAT, 0o600)
          return file if file.flock(File::LOCK_EX | File::LOCK_NB)

          file.close
        end
        return nil if monotonic >= stop

        sleep 0.05
      end
    end

    # The bubblewrap command for the step, built here from checked parts, and
    # the limits it runs under.
    def command(request)
      case request.fetch('run')
      when 'program' then program_step(request)
      when 'pdf_redactor' then redactor_step(request)
      when 'mail_read' then mail_step(request)
      when 'office_read' then office_step(request)
      else raise Refusal, 'unknown kind of step'
      end
    end

    def program_step(request)
      program = request.fetch('program').to_s
      path = program_path(program, self_test: request['self_test'])
      args = arguments(request)
      limits = limits(request, allowed_env: PROGRAM_ENV.fetch(program, {}))
      files = {}
      libreoffice = Bubblewrap::LIBREOFFICE_PROGRAMS.include?(program)
      if libreoffice
        args = Bubblewrap.libreoffice_args(args)
        if args.drop(1).any? { |arg| arg.match?(/\A--?env:/i) }
          raise Refusal, 'the step may not set LibreOffice environment flags'
        end

        files[ProcessRunner::PROFILE_FD] = Bubblewrap::LIBREOFFICE_SETTINGS
      elsif Bubblewrap::JAVA_PROGRAMS.include?(program)
        limits[:env] = limits[:env].merge(
          'JAVA_TOOL_OPTIONS' => Bubblewrap::JAVA_OPTIONS
        )
        limits[:memory] = [limits[:memory], Bubblewrap::JAVA_MEMORY].max
      end
      argv = Bubblewrap.argv(
        bwrap: @bwrap, input_dir: input_dir(request),
        scratch_dir: scratch_dir(request), limits: limits,
        command: [path, *args], libreoffice_profile: libreoffice
      )
      [argv, limits, files]
    end

    def arguments(request)
      args = request.fetch('args')
      raise Refusal, 'the arguments are not a list' unless args.is_a?(Array)

      args.map(&:to_s)
    end

    # One of this cell's programs, or for a self-test /usr/bin/true, found on
    # this cell's PATH and only under /usr, which is all a step sees.
    def program_path(program, self_test:)
      unless CELL_PROGRAMS.fetch(@kind).include?(program) ||
             (self_test == true && program == SELF_TEST_PROGRAM)
        raise Refusal, "#{program} is not one of this cell's programs"
      end

      AlaveteliSandbox.program_path(program, sandboxed: true,
                                             dirs: ENV['PATH'].to_s.split(':'))
    rescue AlaveteliSandbox::Error => e
      raise Refusal, e.message
    end

    # PDFRedactor's worker, from this cell's own copy of its source.
    def redactor_step(request)
      unless @kind == RedactorStep::CELL
        raise Refusal, 'the PDF redactor is not one of this cell’s programs'
      end

      same_worker!(request)

      mode = request.fetch('mode').to_s
      unless RedactorStep::MODES.include?(mode)
        raise Refusal, 'unknown redactor mode'
      end

      depth = Integer(request.fetch('depth'))
      raise Refusal, 'depth must be between 0 and 3' unless depth.between?(0, 3)

      timeout = request['regexp_timeout']
      unless timeout.nil?
        timeout = Float(timeout, exception: false)
        unless timeout&.finite? && timeout.positive?
          raise Refusal, 'regexp_timeout must be a positive number'
        end
      end

      RedactorStep.command(
        bwrap: @bwrap, input_dir: input_dir(request),
        scratch_dir: scratch_dir(request), input_name: input_name(request),
        limits: limits(request, allowed_env: {}), runtime: runtime,
        ruby: RbConfig.ruby, root: @root,
        mode: mode, ocr: request['ocr'] == true,
        depth: depth, regexp_timeout: timeout
      )
    end

    # The mail worker, from this cell's own copy of its source, with this
    # cell's own copies of the gems it loads.
    def mail_step(request)
      unless @kind == MailStep::CELL
        raise Refusal, 'the mail worker is not one of this cell’s programs'
      end
      if @gems.empty?
        raise Refusal, 'this cell has not been told the mail worker’s gems'
      end

      same_worker!(request)

      tools = request.fetch('tools')
      stored = request.fetch('stored')
      unless [tools, stored].all? { |flag| [true, false].include?(flag) }
        raise Refusal, 'tools and stored must each be true or false'
      end

      bodies = request.fetch('bodies')
      unless bodies.is_a?(String) && bodies.match?(MailStep::BODIES)
        raise Refusal, 'bodies must be all, none or a part’s digest'
      end

      MailStep.command(
        bwrap: @bwrap, input_dir: input_dir(request),
        scratch_dir: scratch_dir(request), input_name: input_name(request),
        limits: limits(request, allowed_env: {}), runtime: runtime,
        ruby: RbConfig.ruby,
        root: @root, gem_directories: @gems, tools: tools, bodies: bodies,
        stored: stored
      )
    end

    # The Office worker, from this cell's own copy of its source, with this
    # cell's own copies of the gems it loads. OfficeStep.arguments checks the
    # sections and the sheet limits.
    def office_step(request)
      unless @kind == OfficeStep::CELL
        raise Refusal, 'the Office worker is not one of this cell’s programs'
      end
      if @gems.empty?
        raise Refusal, 'this cell has not been told the Office worker’s gems'
      end

      same_worker!(request)

      OfficeStep.command(
        bwrap: @bwrap, input_dir: input_dir(request),
        scratch_dir: scratch_dir(request), input_name: input_name(request),
        limits: limits(request, allowed_env: {}), runtime: runtime,
        ruby: RbConfig.ruby, root: @root, gem_directories: @gems,
        sections: request.fetch('sections'), sheets: request.fetch('sheets'),
        zip: request['zip']
      )
    end

    def worker_release
      case @kind
      when RedactorStep::CELL then RedactorStep.release(@root)
      when MailStep::CELL then MailStep.release(@root, @gems)
      when OfficeStep::CELL then OfficeStep.release(@root, @gems)
      end
    end

    # A worker step must come from an app whose copy of the worker is this
    # cell's.
    def same_worker!(request)
      return if request['worker'] == worker_release

      raise Refusal, 'the app’s copy of this worker and this cell’s differ; ' \
                     'restart the cell'
    end

    def input_name(request)
      name = request.fetch('input_name').to_s
      unless name.match?(SAFE_NAME) && !name.include?('..')
        raise Refusal, 'bad input name'
      end

      name
    end

    def runtime
      RedactorStep.runtime(RbConfig.ruby) ||
        raise(Refusal, 'the Ruby runtime is outside the system directories')
    end

    def job_dir(request)
      job = request.fetch('job').to_s
      raise Refusal, 'bad job name' unless job.match?(JOB_NAME)

      dir = File.join(@volume, job)
      stat = File.lstat(dir)
      unless stat.directory? && stat.uid == app_uid
        raise Refusal, 'the job is not a directory of the app’s'
      end

      dir
    rescue Errno::ENOENT, Errno::EACCES
      raise Refusal, 'no such job on the conversion volume'
    end

    def input_dir(request)
      subdirectory(request, 'in')
    end

    def scratch_dir(request)
      subdirectory(request, 'scratch')
    end

    def subdirectory(request, name)
      dir = File.join(job_dir(request), name)
      return dir if File.lstat(dir).directory?

      raise Refusal, "the job has no #{name} directory"
    rescue Errno::ENOENT, Errno::EACCES
      raise Refusal, "the job has no #{name} directory"
    end

    # The step's limits, each at most MOST's, and only the allowed environment
    # variables for the step.
    def limits(request, allowed_env: {})
      sent = request.fetch('limits')
      raise Refusal, 'the limits are not an object' unless sent.is_a?(Hash)

      limits = MOST.to_h do |limit, most|
        value = Integer(sent.fetch(limit.to_s))
        raise Refusal, "the #{limit} limit must be positive" if value < 1

        cap = if limit == :processes
                [most, CELL_PROCESSES.fetch(@kind)].min
              else
                most
              end
        [limit, [value, cap].min]
      end
      limits.merge(env: environment(sent.fetch('env', {}), allowed_env))
    end

    def environment(sent, allowed)
      raise Refusal, 'the environment is not an object' unless sent.is_a?(Hash)

      sent.to_h do |variable, value|
        pattern = allowed[variable]
        unless pattern
          raise Refusal, "the step may not set #{variable.to_s[0, 64]}"
        end

        text = value.to_s
        unless text.match?(pattern)
          raise Refusal, "invalid value for #{variable}"
        end

        [variable, text]
      end
    end

    def monotonic
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
  end
end
