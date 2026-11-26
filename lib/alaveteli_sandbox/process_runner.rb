require 'json'
require 'io/nonblock'

module AlaveteliSandbox
  ##
  # Runs one command in its own process group with no stdin, and an empty
  # environment unless told otherwise. It caps what it keeps of stdout and
  # stderr, and kills the whole group on timeout or when stdout passes its cap.
  #
  # With sandboxed, the command is bubblewrap, given descriptor 3 for
  # --info-fd and descriptor 4 for --block-fd. bubblewrap writes the sandbox's
  # first process to the info pipe once the sandbox is set up (an empty info
  # pipe means it never started), then waits on the block pipe before running
  # the program. In that pause the runner records the sandbox's PID namespace.
  # After the run it kills anything still in that namespace, and waits until
  # nothing is, so no process from the step is left by the time it returns.
  # The step's process group isn't enough: a process can leave its group.
  class ProcessRunner
    READ_SIZE = 64 * 1024
    INFO_FD = 3
    BLOCK_FD = 4
    PROFILE_FD = 5
    SECCOMP_FD = 6
    INFO_LIMIT = 4096
    TERM_GRACE = 2
    # How long to wait for a sandbox's namespace to empty after its step.
    DRAIN_SECONDS = 5

    # False only in specs, which stub it to stand in for bubblewrap with a
    # script that makes no namespace.
    def self.confirm_namespace?
      true
    end

    Result = Struct.new(
      :status, :stdout, :stderr, :info, :timed_out, :stdout_overflow,
      :sandboxed, :namespace_unconfirmed, :outlived, keyword_init: true
    ) do
      def success?
        !timed_out && !stdout_overflow && !outlived && status&.success?
      end

      # The signal that ended the program. bubblewrap and shells report a
      # signalled child as exit status 128 + signal, so that counts too.
      def signal
        return status.termsig if status&.signaled?

        code = status&.exitstatus.to_i
        code - 128 if code > 128 && code < 128 + 65
      end

      # bubblewrap never writes its info descriptor when setup fails before the
      # command. A sandbox whose PID namespace couldn't be confirmed counts as
      # one that didn't start: its program was never run. Child stderr is
      # untrusted once the sandbox has started, so it is never checked here.
      def sandbox_failed?
        return false unless sandboxed
        return true if namespace_unconfirmed
        return false if success? || timed_out || stdout_overflow || outlived

        info.to_s.empty?
      end

      def status_description
        return 'no status' unless status
        return "signal #{status.termsig}" if status.signaled?

        "exit #{status.exitstatus}"
      end
    end

    def initialize(argv, chdir:, timeout:, stdout_limit:, stderr_limit:,
                   sandboxed: false, env: {}, clear_env: true,
                   files: {}, seccomp: nil)
      @argv = argv
      @chdir = chdir
      @timeout = timeout
      @limits = { stdout: stdout_limit, stderr: stderr_limit }
      @sandboxed = sandboxed
      @env = env.to_h.transform_keys(&:to_s).transform_values(&:to_s)
      @clear_env = clear_env
      @files = files
      @seccomp = if !seccomp.nil?
                   seccomp
                 elsif @sandboxed
                   Seccomp.bpf
                 end
    end

    def run
      pipes = { stdout: IO.pipe, stderr: IO.pipe }
      if @sandboxed
        pipes[:info] = IO.pipe
        pipes[:block] = IO.pipe
        # Ruby can create pipes with O_NONBLOCK. The child's control protocol
        # must wait for namespace verification before its pause read completes.
        pipes[:info][1].nonblock = false
        pipes[:block][0].nonblock = false
      end

      options = {
        in: File::NULL, out: pipes[:stdout][1], err: pipes[:stderr][1],
        chdir: @chdir, pgroup: true, unsetenv_others: @clear_env,
        close_others: true
      }
      extra_ios = []
      if @sandboxed
        options[INFO_FD] = pipes[:info][1]
        options[BLOCK_FD] = pipes[:block][0]
        @files.each do |fd, path|
          io = File.open(path, 'rb')
          extra_ios << io
          options[fd] = io
        end
        if @seccomp
          seccomp_r, seccomp_w = IO.pipe
          seccomp_r.nonblock = false
          seccomp_w.binmode
          seccomp_w.write(@seccomp)
          seccomp_w.close
          extra_ios << seccomp_r
          options[SECCOMP_FD] = seccomp_r
        end
      end

      @deadline = monotonic + @timeout
      @status = nil
      pid = Process.spawn(@env, *@argv, options)
      [pipes[:stdout][1], pipes[:stderr][1]].each(&:close)
      if @sandboxed
        pipes[:info][1].close
        pipes[:block][0].close
      end
      extra_ios.each(&:close)

      readers = { stdout: pipes[:stdout][0], stderr: pipes[:stderr][0] }
      output = { info: +'', namespace_unconfirmed: false, outlived: false }
      namespace = nil
      if @sandboxed
        output[:info] = read_info(pipes[:info][0])
        namespace = :unchecked
        namespace = namespace_of(output[:info]) if confirm_namespace?
        if namespace.nil?
          # No confirmed namespace, for whatever reason: setup failed, the
          # wait for it ran out while setup was still going, or the namespace
          # isn't a new one. The program is never released. bubblewrap is
          # killed, and the block pipe stays open (a closed one would also
          # release it) until bubblewrap is dead and has taken the sandbox
          # with it.
          output[:namespace_unconfirmed] = true
          kill_group(pid, grace: 0)
        else
          release(pipes[:block][1])
        end
      end

      output.merge!(collect(pid, readers))
      output[:timed_out] = true unless wait_until_deadline(pid)
      # Nothing the step started outlives it: its process group, and
      # everything left in its sandbox's PID namespace.
      signal_group('KILL', pid)
      output[:outlived] = !drain(namespace) if namespace.is_a?(String)

      Result.new(status: @status, sandboxed: @sandboxed, **output)
    ensure
      pipes&.each_value { |pair| pair.each { |io| io.close unless io.closed? } }
      extra_ios&.each { |io| io.close unless io.closed? }
      seccomp_w.close unless seccomp_w.nil? || seccomp_w.closed?
    end

    private

    def confirm_namespace?
      self.class.confirm_namespace?
    end

    # Lets bubblewrap run the program.
    def release(block)
      block.write('x')
      block.close
    rescue Errno::EPIPE
      nil # bubblewrap has already exited
    end

    # The info bubblewrap writes once the sandbox is set up, or '' if it
    # closed the pipe without (setup failed).
    def read_info(io)
      info = +''
      while info.bytesize < INFO_LIMIT
        remaining = @deadline - monotonic
        break if remaining <= 0
        break unless io.wait_readable(remaining)

        chunk = io.read_nonblock(READ_SIZE, exception: false)
        break if chunk.nil?
        next if chunk == :wait_readable

        info << chunk
        break if parsed(info)
      end
      info
    end

    def parsed(info)
      JSON.parse(info)
    rescue JSON::ParserError
      nil
    end

    # The PID namespace of the sandbox's first process, which bubblewrap holds
    # paused before the program runs. nil unless it is a new namespace.
    def namespace_of(info)
      child = parsed(info)&.fetch('child-pid', nil).to_i
      return nil unless child.positive?

      namespace = File.readlink("/proc/#{child}/ns/pid")
      namespace unless namespace == File.readlink('/proc/self/ns/pid')
    rescue SystemCallError
      nil
    end

    # Kills whatever is left in the namespace until nothing is. Returns false
    # if something is still there after DRAIN_SECONDS.
    def drain(namespace)
      stop = monotonic + DRAIN_SECONDS
      loop do
        left = processes_in(namespace)
        return true if left.empty?
        return false if monotonic >= stop

        left.each { |pid| kill(pid) }
        sleep 0.02
      end
    end

    def kill(pid)
      Process.kill('KILL', pid)
    rescue Errno::ESRCH, Errno::EPERM
      nil
    end

    # Live processes in the namespace. Zombies (exited, waiting for their
    # parent to collect them) are left out: they can't do anything.
    def processes_in(namespace)
      dead_states = %w[Z X]
      Dir.children('/proc').filter_map do |entry|
        next unless entry.match?(/\A\d+\z/)

        pid = entry.to_i
        next if pid == Process.pid
        next unless File.readlink("/proc/#{entry}/ns/pid") == namespace
        next if dead_states.include?(state_of(entry))

        pid
      rescue SystemCallError
        nil
      end
    end

    # The one-letter state in /proc/PID/stat. It follows the command name in
    # brackets, and a process can set its own name to anything, ") Z" included,
    # so it is read after the last ")".
    def state_of(entry)
      stat = File.read("/proc/#{entry}/stat")
      stat[(stat.rindex(')') + 1)..][/\S/]
    end

    def collect(pid, readers)
      buffers = readers.transform_values { +''.b }
      open = readers.invert
      timed_out = false
      overflow = false

      until open.empty? || overflow
        remaining = @deadline - monotonic
        if remaining <= 0
          timed_out = true
          kill_group(pid)
          break
        end

        ready, = IO.select(open.keys, nil, nil, remaining)
        next unless ready

        ready.each do |io|
          name = open[io]
          chunk = io.read_nonblock(READ_SIZE, exception: false)
          next if chunk == :wait_readable

          if chunk.nil?
            open.delete(io)
            next
          end

          room = @limits[name] - buffers[name].bytesize
          buffers[name] << chunk.byteslice(0, room) if room.positive?
          next unless chunk.bytesize > room && name == :stdout

          overflow = true
          kill_group(pid, grace: 0)
          break
        end
      end

      {
        stdout: buffers[:stdout], stderr: buffers[:stderr],
        timed_out: timed_out, stdout_overflow: overflow
      }
    end

    # Reaps the process if it has exited by the deadline. Returns false, after
    # killing its group, if it hadn't.
    def wait_until_deadline(pid)
      loop do
        return true if reaped?(pid)

        if monotonic >= @deadline
          kill_group(pid)
          reaped?(pid) || (@status = Process.wait2(pid).last)
          return false
        end

        sleep 0.05
      end
    end

    # TERM, then KILL after the grace period. The whole group gets KILL in the
    # end, so nothing it started outlives it.
    def kill_group(pid, grace: TERM_GRACE)
      if grace.positive?
        signal_group('TERM', pid)
        stop = monotonic + grace
        sleep 0.1 until reaped?(pid) || monotonic >= stop
      end
      signal_group('KILL', pid)
    end

    def reaped?(pid)
      return true if @status

      reaped = Process.wait2(pid, Process::WNOHANG)
      @status = reaped.last if reaped
      !@status.nil?
    end

    def signal_group(signal, pid)
      Process.kill(signal, -pid)
    rescue Errno::ESRCH, Errno::EPERM
      nil
    end

    def monotonic
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
  end
end
