require 'fileutils'
require 'find'
require 'tmpdir'

module AlaveteliSandbox
  # Private directory (read-only input, writable scratch) for a conversion job.
  # Steps see only these dirs at their real paths; outputs leave via #read and
  # #copy_out, which re-verify each file on open. With cells, scratch is open
  # to the cells' group only during a step, and cell-owned dirs are refused.
  # See doc/FORK.md.
  class Job
    LIBREOFFICE_PROFILE = Bubblewrap::LIBREOFFICE_PROFILE
    LIBREOFFICE_SETTINGS = Bubblewrap::LIBREOFFICE_SETTINGS

    DEFAULT_LIMITS = {
      output_files: 1000,
      output_bytes: 1024 * 1024 * 1024
    }.freeze

    # Per-step defaults; env adds to an empty environment when sandboxed, or
    # to the inherited environment when off.
    STEP_DEFAULTS = {
      env: {}.freeze,
      timeout: 120,
      memory: 2 * 1024 * 1024 * 1024,
      file_size: 512 * 1024 * 1024,
      open_files: 256,
      processes: 256,
      stdout: 64 * 1024 * 1024,
      stderr: 64 * 1024,
      tmp_size: 512 * 1024 * 1024
    }.freeze

    JAVA_PROGRAMS = Bubblewrap::JAVA_PROGRAMS
    JAVA_OPTIONS = Bubblewrap::JAVA_OPTIONS
    JAVA_MEMORY = Bubblewrap::JAVA_MEMORY

    # Ruby has no O_DIRECTORY (and its value differs by architecture), so
    # directories are opened like files and checked with fstat.
    FILE_FLAGS = File::RDONLY | File::NOFOLLOW | File::NONBLOCK

    attr_reader :input_name

    # cell: for a self-test, the cell to run it in.
    def self.open(input: nil, input_name: 'input', limits: {},
                  self_test: false, cell: nil)
      job = new(sandboxed: AlaveteliSandbox.required?,
                in_cells: Cell.configured?, input_name: input_name,
                limits: limits, self_test: self_test, cell: cell)
      job.prepare(input)
      yield job
    ensure
      job&.remove
    end

    def initialize(sandboxed:, input_name:, limits:, self_test:,
                   in_cells: false, cell: nil)
      @sandboxed = sandboxed
      @in_cells = in_cells
      @input_name = AlaveteliSandbox::Job.safe_name!(input_name)
      @limits = DEFAULT_LIMITS.merge(limits)
      @self_test = self_test
      @self_test_cell = cell
    end

    def sandboxed?
      @sandboxed
    end

    def in_cells?
      @in_cells
    end

    def input
      File.join(input_dir, input_name)
    end

    def scratch(name = nil)
      name ? File.join(scratch_dir, self.class.safe_name!(name)) : scratch_dir
    end

    # Runs one step. Returns a ProcessRunner::Result on success; raises Refused,
    # TimedOut, LimitExceeded or Failed otherwise.
    def run(program, *args, **options)
      options = STEP_DEFAULTS.merge(options)
      refuse!(:disabled, program) if AlaveteliSandbox.disabled?
      allowed!(program)
      args = args.map(&:to_s)
      return run_in_cell(program, args, options) if in_cells?

      profile = false
      if sandboxed?
        options = java_options(options) if JAVA_PROGRAMS.include?(program)
        if Bubblewrap::LIBREOFFICE_PROGRAMS.include?(program)
          args = Bubblewrap.libreoffice_args(args)
          profile = true
        end
      end

      path = AlaveteliSandbox.program_path(program, sandboxed: sandboxed?)
      files = profile ? { ProcessRunner::PROFILE_FD => LIBREOFFICE_SETTINGS } : {}
      argv = command_for(path, args, options, libreoffice_profile: profile)
      execute(program, argv, options, files: files)
    end

    def run_in_cell(program, args, options)
      if JAVA_PROGRAMS.include?(program)
        options = options.merge(memory: [options[:memory], JAVA_MEMORY].max)
      end
      if Bubblewrap::LIBREOFFICE_PROGRAMS.include?(program)
        args = args.reject { |arg| arg.start_with?('-env:UserInstallation=') }
      end
      # The cell finds the program itself. (Callers that ask whether a
      # program is installed, to offer a feature, still look on this machine.)
      cell = AlaveteliSandbox.cell_for(program)
      cell = @self_test_cell if program == SELF_TEST_PROGRAM
      execute_in_cell(cell, program, options,
                      'run' => 'program', 'program' => program,
                      'args' => args, 'self_test' => @self_test)
    end
    private :run_in_cell

    # Runs PDFRedactor in one namespace (RedactorStep); limit hits fail the
    # step. regexp_timeout: app Regexp.timeout for rules (nil for none).
    def run_pdf_redactor(mode:, ocr:, depth:, regexp_timeout:)
      refuse!(:disabled, 'pdf-redactor') if AlaveteliSandbox.disabled?
      refuse!(:sandbox_required, 'pdf-redactor') unless sandboxed?

      if in_cells?
        # The cell runs its own copy of the worker with its own Ruby.
        return execute_in_cell(
          RedactorStep::CELL, 'pdf-redactor',
          STEP_DEFAULTS.merge(RedactorStep::LIMITS),
          'run' => 'pdf_redactor', 'mode' => mode, 'input_name' => input_name,
          'ocr' => ocr ? true : false, 'depth' => depth,
          'regexp_timeout' => regexp_timeout&.to_f,
          'worker' => RedactorStep.release
        )
      end

      runtime = RedactorStep.runtime(RbConfig.ruby)
      refuse!(:ruby_runtime_outside_system, 'pdf-redactor') unless runtime

      argv, limits = RedactorStep.command(
        bwrap: AlaveteliSandbox.bwrap, input_dir: input_dir,
        scratch_dir: scratch_dir, input_name: input_name,
        limits: STEP_DEFAULTS, runtime: runtime, ruby: RbConfig.ruby,
        root: Cell::ROOT, mode: mode,
        ocr: ocr, depth: depth, regexp_timeout: regexp_timeout
      )
      execute('pdf-redactor', argv, limits)
    end

    # Runs script/mail_worker.rb (MailStep); always sandboxed. Under
    # CONVERTERS_DISABLED mail is still read, while tnef/msgconvert refuse.
    # bodies: 'all', 'none', or part digest; stored: match MailStep::STORED;
    # timeout: caps step time (and cell slot wait) below MailStep::LIMITS.
    def run_mail_read(bodies:, stored:, timeout: nil)
      refuse!(:sandbox_required, 'mail-worker') unless sandboxed?
      raise ArgumentError, 'bad bodies' unless bodies.match?(MailStep::BODIES)

      gems = MailStep.gem_directories
      tools = !AlaveteliSandbox.disabled?
      limits = STEP_DEFAULTS.merge(MailStep::LIMITS)
      limits[:timeout] = [timeout, limits[:timeout]].min if timeout
      if in_cells?
        # The cell runs its own worker copy, Ruby, and gems.
        return execute_in_cell(
          MailStep::CELL, 'mail-worker', limits,
          'run' => 'mail_read', 'input_name' => input_name,
          'tools' => tools, 'bodies' => bodies,
          'stored' => stored ? true : false,
          'worker' => MailStep.release(Cell::ROOT, gems)
        )
      end

      runtime = RedactorStep.runtime(RbConfig.ruby)
      refuse!(:ruby_runtime_outside_system, 'mail-worker') unless runtime

      argv, limits = MailStep.command(
        bwrap: AlaveteliSandbox.bwrap, input_dir: input_dir,
        scratch_dir: scratch_dir, input_name: input_name,
        limits: limits, runtime: runtime, ruby: RbConfig.ruby,
        root: Cell::ROOT, gem_directories: gems, tools: tools,
        bodies: bodies, stored: stored
      )
      execute('mail-worker', argv, limits)
    end

    # Runs script/office_worker.rb (OfficeStep); always sandboxed, unaffected
    # by CONVERTERS_DISABLED. sections, sheets, and zip follow
    # OfficeStep.arguments.
    def run_office_read(sections:, sheets: nil, zip: nil)
      refuse!(:sandbox_required, 'office-worker') unless sandboxed?
      OfficeStep.arguments(sections, sheets, zip)

      gems = OfficeStep.gem_directories
      limits = STEP_DEFAULTS.merge(OfficeStep::LIMITS)
      if in_cells?
        # The cell runs its own worker copy, Ruby, and gems.
        payload = {
          'run' => 'office_read', 'input_name' => input_name,
          'sections' => sections, 'sheets' => sheets,
          'worker' => OfficeStep.release(Cell::ROOT, gems)
        }
        payload['zip'] = zip if zip
        return execute_in_cell(
          OfficeStep::CELL, 'office-worker', limits, payload
        )
      end

      runtime = RedactorStep.runtime(RbConfig.ruby)
      refuse!(:ruby_runtime_outside_system, 'office-worker') unless runtime

      argv, limits = OfficeStep.command(
        bwrap: AlaveteliSandbox.bwrap, input_dir: input_dir,
        scratch_dir: scratch_dir, input_name: input_name,
        limits: limits, runtime: runtime, ruby: RbConfig.ruby,
        root: Cell::ROOT, gem_directories: gems, sections: sections,
        sheets: sheets, zip: zip
      )
      execute('office-worker', argv, limits)
    end

    # Audits scratch after a step: only directories and single-link regular
    # files, within job count/byte limits. ProcessRunner has already drained
    # the sandbox namespace; reads still go through #open_file. With cells,
    # every directory must be app-owned and readable so cells cannot mutate
    # or hide entries after audit.
    def audit!(program)
      count = 0
      bytes = 0
      Find.find(scratch_dir, ignore_error: !in_cells?) do |path|
        next if path == scratch_dir

        stat = File.lstat(path)
        name = path.delete_prefix("#{scratch_dir}/")
        audit_entry!(program, stat, name)

        count += 1
        bytes += stat.size if stat.file?
        audit_totals!(program, count, bytes)
      end
    rescue SystemCallError => e
      raise unless in_cells?

      unexpected!(program, "entry that can't be read (#{e.message})")
    end

    # Opens a file the job's steps could have written (or its input) for
    # reading, without following a symbolic link anywhere in its path: each
    # directory is opened in turn, relative to the last, refusing links. Then
    # the file must be regular, have one link and be at most max bytes.
    # Paths outside the job's input and scratch areas are refused.
    def open_file(path, max:)
      base, parts = within_job(path)
      file = walk(base, parts)
      begin
        stat = file.stat
        unless stat.file?
          raise Failed, "#{relative(path)} is not a regular file"
        end
        raise Failed, "#{relative(path)} has other links" unless stat.nlink == 1

        too_large!(relative(path), max) if stat.size > max
        file.binmode
        yield file
      ensure
        file.close
      end
    end

    # The bytes of a file in the job, at most max. No more is asked of the
    # read than the file holds: max may be as much as a step's largest file,
    # and Ruby asks for room for all a read may give before it reads any.
    def read_file(path, max:)
      data = open_file(path, max: max) do |file|
        file.read(file.size + 1)
      end.to_s
      too_large!(relative(path), max) if data.bytesize > max
      data
    end

    # Copies a file in the job to an IO, or to a new file at a path (which is
    # never followed if it's a link), at most max bytes.
    def copy_file(path, to:, max:)
      copied = open_file(path, max: max) do |file|
        if to.respond_to?(:write)
          IO.copy_stream(file, to, max + 1)
        else
          flags = File::WRONLY | File::CREAT | File::TRUNC | File::NOFOLLOW
          File.open(to, flags, 0o600) do |out|
            out.binmode
            IO.copy_stream(file, out, max + 1)
          end
        end
      end
      too_large!(relative(path), max) if copied > max
      copied
    end

    # Names of the regular files in the scratch area, sorted, optionally
    # matching a pattern. Raises if the step left anything unexpected or too
    # much. Names are whatever the program chose (TNEF and LibreOffice keep
    # spaces and accents), so pass them back to #read, not into a command.
    def files(pattern = nil)
      names = Dir.children(scratch_dir)
      most = @limits[:output_files]
      raise LimitExceeded, "more than #{most} output files" if names.size > most

      total = 0
      safe = names.sort.select do |name|
        stat = File.lstat(File.join(scratch_dir, name))
        unless stat.file? && stat.nlink == 1
          raise Failed, "unexpected output #{name.inspect}"
        end

        total += stat.size
        pattern.nil? || name.match?(pattern)
      end
      if total > @limits[:output_bytes]
        raise LimitExceeded, "outputs exceed #{@limits[:output_bytes]} bytes"
      end

      safe
    end

    def exist?(name)
      files.include?(name)
    end

    def read(name, max:)
      read_file(File.join(scratch_dir, self.class.output_name!(name)), max: max)
    end

    def copy_out(name, to:, max:)
      path = File.join(scratch_dir, self.class.output_name!(name))
      copy_file(path, to: to, max: max)
    end

    # A name a caller may use in a command: letters, digits, dot, dash and
    # underscore.
    def self.safe_name!(name)
      name = name.to_s
      return name if name.match?(SAFE_NAME) && !name.include?('..')

      raise ArgumentError, "unsafe job file name #{name.inspect}"
    end

    # A name a program wrote: any single path component.
    def self.output_name!(name)
      name = name.to_s
      if name.empty? || name.include?('/') || name.include?("\0") ||
         %w[. ..].include?(name)
        raise ArgumentError, "unsafe output name #{name.inspect}"
      end

      name
    end

    # Called by .open
    def prepare(input)
      refuse!(:cells_need_the_sandbox, '-') if in_cells? && !sandboxed?
      if sandboxed? && (problem = AlaveteliSandbox.volume_problem)
        AlaveteliSandbox.log(:volume_not_mounted, '-', problem)
        raise Refused, problem
      end

      begin
        @dir = make_directory
        Dir.mkdir(input_dir, 0o700)
        Dir.mkdir(scratch_dir, 0o700)
        write_input(input) unless input.nil?
        share_with_cells if in_cells?

      rescue Errno::ENOSPC, Errno::EDQUOT => e
        # A full volume: nothing was run, as with a missing one.
        AlaveteliSandbox.log(:volume_full, '-', e.message)
        raise Refused, "could not prepare the job: #{e.message}"
      end
    end

    # Called by .open
    def remove
      return unless @dir && File.exist?(@dir)

      in_cells? ? remove_shared : FileUtils.remove_entry_secure(@dir)
    end

    private

    # With cells the directory's name is one their users can't guess: they
    # can enter any job they can name, and read its input.
    def make_directory
      unless in_cells?
        return Dir.mktmpdir('job-', sandboxed? ? AlaveteliSandbox.volume : nil)
      end

      dir = File.join(AlaveteliSandbox.volume, "job-#{SecureRandom.hex(16)}")
      Dir.mkdir(dir, 0o700)
      dir
    end

    # FileUtils trusts that nobody else can write in the tree. A cell's user
    # can, so each directory is emptied through its own descriptor. A job
    # that can't be removed is logged and fails, as its files stay on the
    # volume.
    def remove_shared
      directory(@dir) { |dir| empty(dir) }
      Dir.rmdir(@dir)
    rescue SystemCallError => e
      AlaveteliSandbox.log(:job_not_removed, '-',
                           "#{File.basename(@dir)}: #{e.message}")
      raise Failed, "could not remove the job's files: #{e.message}"
    end

    def input_dir
      File.join(@dir, 'in')
    end

    def scratch_dir
      File.join(@dir, 'scratch')
    end

    def write_input(input)
      path = File.join(input_dir, input_name)
      File.open(path, File::WRONLY | File::CREAT | File::EXCL, 0o600) do |file|
        file.binmode
        # A String is the bytes themselves; a Pathname is a file to copy.
        if input.is_a?(Pathname)
          File.open(input, 'rb') { |source| IO.copy_stream(source, file) }
        elsif input.respond_to?(:read)
          IO.copy_stream(input, file)
        else
          file.write(input.to_s)
        end
      end
      File.chmod(0o400, path)
    end

    def java_options(options)
      env = { 'JAVA_TOOL_OPTIONS' => JAVA_OPTIONS }.merge(options[:env])
      options.merge(memory: [options[:memory], JAVA_MEMORY].max, env: env)
    end

    def allowed!(program)
      return if PROGRAMS.include?(program)
      return if @self_test && program == SELF_TEST_PROGRAM

      refuse!(:not_allowed, program)
    end

    def execute(program, argv, options, files: {})
      checked(program) do
        ProcessRunner.new(
          argv, chdir: scratch_dir, timeout: options[:timeout],
                stdout_limit: options[:stdout], stderr_limit: options[:stderr],
                sandboxed: sandboxed?, env: sandboxed? ? {} : options[:env],
                clear_env: sandboxed?, files: files
        ).run
      end
    end

    # Has a converter cell run the step on this job's directory, which the
    # cell shares, then checks it the same way. The scratch area is opened to
    # the cells for the step and closed again before anything is checked.
    def execute_in_cell(cell, program, options, step)
      limits = options.slice(:timeout, :memory, :file_size, :open_files,
                             :processes, :stdout, :stderr, :tmp_size, :env)
      checked(program) do
        opened = open_scratch
        begin
          Cell.run(cell, step, job: File.basename(@dir), limits: limits)
        rescue Refused => e
          AlaveteliSandbox.log(:sandbox_unavailable, program, e.message)
          raise
        ensure
          close_scratch(program, opened)
        end
      end
    end

    # Shares the new job with the cells' users, through the volume's group and
    # with nobody else. They can enter the job they are named and read its
    # input; they can't list the volume's jobs or change the input. The
    # scratch area is theirs to write in only during a step (#open_scratch).
    def share_with_cells
      @group = File.stat(AlaveteliSandbox.volume).gid
      { @dir => 0o710, input_dir => 0o750 }.each do |path, mode|
        File.chown(nil, @group, path)
        File.chmod(mode, path)
      end
      if File.file?(input)
        File.chown(nil, @group, input)
        File.chmod(0o440, input)
      end
      close_scratch('-', open_scratch)
    end

    # Opens the scratch area to the cells' group for a step: read and write on
    # everything this process put there, whose umask may have kept the group
    # out. setgid keeps what either side adds to a directory in the group.
    # Returns this process's directories, as paths below the scratch area.
    def open_scratch
      directories = []
      own_entries do |entry, path|
        entry.chown(nil, @group)
        if entry.stat.directory?
          entry.chmod(0o2770)
          directories << path
        else
          entry.chmod(0o660)
        end
      end
      directories
    end

    # Closes this process's directories in the scratch area to the cells'
    # group again, the scratch area itself first. From then on nobody else can
    # add, remove or rename anything in them. Every directory that was this
    # process's before the step (opened) must still be: one that was moved
    # away, or replaced with a cell's, fails the step.
    def close_scratch(program, opened)
      closed = []
      own_entries do |entry, path|
        next unless entry.stat.directory?

        entry.chmod(0o2700)
        closed << path
      end
      missing = opened - closed
      return if missing.empty?

      unexpected!(program, "directory in place of #{missing.first.inspect}")
    end

    # Yields each directory and regular file in the scratch area that is this
    # process's, with its path below the scratch area ('' for the area
    # itself), a directory before what it holds. Each is opened without
    # following a link. Other users' entries are left alone, and their
    # directories are not looked into.
    def own_entries(&block)
      directory(scratch_dir) { |dir| own_entries_in(dir, '', &block) }
    end

    def own_entries_in(dir, path, &block)
      return unless dir.stat.uid == Process.euid

      yield dir, path
      Dir.children(descriptor_path(dir)).each do |name|
        open_entry(dir, name) do |entry|
          below = path.empty? ? name : "#{path}/#{name}"
          stat = entry.stat
          if stat.directory?
            own_entries_in(entry, below, &block)
          elsif stat.file? && stat.uid == Process.euid
            yield entry, below
          end
        end
      end
    end

    # Yields a name in a directory, opened without following a link. Yields
    # nothing for a link, a socket, something that has gone, or something of
    # a cell's that can't be opened.
    def open_entry(dir, name)
      entry = open_without_following(descriptor_path(dir, name))
      return unless entry

      begin
        yield entry
      ensure
        entry.close
      end
    end

    def open_without_following(path)
      File.open(path, FILE_FLAGS)
    rescue Errno::ELOOP, Errno::ENOENT, Errno::EACCES, Errno::ENXIO
      nil
    end

    # Removes everything in a directory, without following a link put where
    # a directory was.
    def empty(dir)
      Dir.children(descriptor_path(dir)).each do |name|
        path = descriptor_path(dir, name)
        begin
          File.unlink(path)
        rescue Errno::EISDIR, Errno::EPERM
          directory(path) { |inner| empty(inner) }
          Dir.rmdir(path)
        end
      end
    end

    # Yields a directory opened without following a link.
    def directory(path)
      dir = open_directory(path)
      yield dir
    ensure
      dir&.close
    end

    # A path to an open directory, or to a name in it, that goes through the
    # descriptor: whatever is done to the directory's own path meanwhile, it
    # reaches the directory that was opened.
    def descriptor_path(dir, name = nil)
      ["/proc/self/fd/#{dir.fileno}", name].compact.join('/')
    end

    def checked(program)
      begin
        result = yield
      rescue SystemCallError => e
        raise unless sandboxed?

        AlaveteliSandbox.log(:sandbox_unavailable, program, e.message)
        raise Refused, "sandbox could not start #{program}: #{e.message}"
      end

      if result.outlived
        AlaveteliSandbox.log(:outlived, program)
        raise Failed, "processes from #{program} outlived the step"
      end
      unless result.sandboxed &&
             (result.namespace_unconfirmed || result.info.to_s.empty?)
        audit!(program)
      end
      check!(program, result)
      result
    end

    def command_for(path, args, options, libreoffice_profile: false)
      return [path, *args] unless sandboxed?

      Bubblewrap.argv(
        bwrap: AlaveteliSandbox.bwrap,
        input_dir: input_dir, scratch_dir: scratch_dir,
        command: [path, *args], limits: options,
        libreoffice_profile: libreoffice_profile
      )
    end

    def check!(program, result)
      if result.sandbox_failed?
        AlaveteliSandbox.log(:sandbox_unavailable, program, result.stderr)
        reason = first_line(result.stderr)
        raise Refused, "sandbox could not start #{program}: #{reason}"
      end

      if result.timed_out
        AlaveteliSandbox.log(:timeout, program)
        raise TimedOut, "#{program} timed out"
      end

      if result.stdout_overflow
        AlaveteliSandbox.log(:limit_exceeded, program, 'stdout')
        raise LimitExceeded, "#{program} wrote too much output"
      end

      if result.signal == Signal.list['XFSZ']
        AlaveteliSandbox.log(:limit_exceeded, program, 'file size')
        raise LimitExceeded, "#{program} wrote a file over its size limit"
      end

      return if result.success?

      AlaveteliSandbox.log(:failed, program, result.stderr)
      message = "#{program} failed (#{result.status_description})"
      raise Failed.new(message, result)
    end

    def within_job(path)
      path = File.expand_path(path.to_s)
      [input_dir, scratch_dir].each do |base|
        next unless path.start_with?("#{base}/")

        parts = path.delete_prefix("#{base}/").split('/')
        next if parts.empty? || parts.any? { |part| %w[. ..].include?(part) }

        return [base, parts]
      end
      raise ArgumentError, "#{path} is not in this job"
    end

    # Opens base/parts..., each directory relative to the one before through
    # its /proc/self/fd entry, so a link anywhere on the way is refused rather
    # than followed. (Without /proc, as on a Mac in development, only the last
    # name is protected.)
    def walk(base, parts)
      unless File.directory?('/proc/self/fd')
        return File.open(File.join(base, *parts), FILE_FLAGS)
      end

      dir = open_directory(base)
      parts[0..-2].each do |part|
        inner = open_directory("/proc/self/fd/#{dir.fileno}/#{part}")
        dir.close
        dir = inner
      end
      File.open("/proc/self/fd/#{dir.fileno}/#{parts.last}", FILE_FLAGS)
    rescue Errno::ELOOP, Errno::ENOTDIR
      raise Failed, "#{File.join(*parts)} is, or is inside, a symbolic link"
    ensure
      dir&.close unless dir.nil? || dir.closed?
    end

    def open_directory(path)
      dir = File.open(path, FILE_FLAGS)
      return dir if dir.stat.directory?

      dir.close
      raise Errno::ENOTDIR, path
    end

    def relative(path)
      File.expand_path(path.to_s).delete_prefix("#{@dir}/")
    end

    def audit_entry!(program, stat, name)
      unless stat.directory? || (stat.file? && stat.nlink == 1)
        unexpected!(program, "#{stat.ftype} (#{name})")
      end
      return unless in_cells? && stat.directory? && stat.uid != Process.euid

      unexpected!(program, "directory of the cell's (#{name})")
    end

    def audit_totals!(program, count, bytes)
      files, most = @limits.values_at(:output_files, :output_bytes)
      if count > files
        unexpected!(program, "number of files (over #{files})",
                    error: LimitExceeded)
      end
      return unless bytes > most

      unexpected!(program, "amount of output (over #{most} bytes)",
                  error: LimitExceeded)
    end

    def unexpected!(program, found, error: Failed)
      AlaveteliSandbox.log(:unexpected_output, program, found)
      raise error, "#{program} left an unexpected #{found}"
    end

    def too_large!(name, max)
      raise LimitExceeded, "#{name} is larger than #{max} bytes"
    end

    def refuse!(reason, program)
      AlaveteliSandbox.log(reason, program)
      raise Refused, "#{program}: #{reason}"
    end

    def first_line(text)
      text.to_s.lines.first.to_s.strip
    end
  end
end
