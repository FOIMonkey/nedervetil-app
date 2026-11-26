# frozen_string_literal: true

# Reads the body of one incoming email: splits it into its parts, unpacking
# the messages attached to it, and leaves a file for each part and a report
# of them in the scratch area (MailHandler::Report says what is in both).
#
# This script runs only inside the sandbox's namespace
# (AlaveteliSandbox::MailStep). It has no Rails boot, database access,
# credentials or network, and Ruby looks for no gems: it is given the
# directories of the few it loads. tnef and msgconvert run in that same
# namespace, as its own child processes, within the outer step's limits.
#
#   ruby --disable-gems -I <each gem directory> script/mail_worker.rb \
#     <the email> <the scratch area> <tools> <bodies> \
#     [<a stored file to find the original of>]
#
# tools is 1, or 0 when converters are switched off (CONVERTERS_DISABLED):
# the mail is still read, and tnef and msgconvert refuse, as they do in the
# app. bodies says which parts' bytes to leave: all, none, or one part's
# digest.
#
# It ends successfully when the report is written (a mail past the part
# limits is reported, not failed). Otherwise the one line it writes to
# stderr says why: NotLoaded when it could not load its own code,
# ReadRefused when tnef or msgconvert could not be run or ran out of time,
# and the error's class when the read itself failed. Nothing else reaches
# stderr: what the mail gem warns of quotes the mail.
require 'fileutils'
require 'find'
require 'json'
require 'tmpdir'

# Where this worker says why it failed. Everything else written to stderr
# from here on is dropped.
SAID = $stderr.dup
# Not when a spec loads this file for the stand-in below.
$stderr.reopen(File::NULL) if $PROGRAM_NAME == __FILE__

# A stand-in for the app's AlaveteliSandbox, with the parts the walk uses and
# the same errors for the same reasons, so the walk treats a tool's failure
# here as it does in the app (AlaveteliSandbox::Job). Inside the namespace a
# tool is a plain child process of this one.
module AlaveteliSandbox
  Error = Class.new(StandardError)
  Refused = Class.new(Error)
  TimedOut = Class.new(Error)
  LimitExceeded = Class.new(Error)
  Result = Struct.new(:stderr, keyword_init: true)

  # The program ran and exited unsuccessfully.
  class Failed < Error
    attr_reader :result

    def initialize(message, result = nil)
      super(message)
      @result = result
    end
  end

  PROGRAMS = %w[tnef msgconvert].freeze
  SAFE_NAME = /\A[A-Za-z0-9][A-Za-z0-9._-]{0,127}\z/

  # Whether converters are switched off (CONVERTERS_DISABLED). The worker is
  # told.
  def self.disabled?
    @disabled == true
  end

  def self.disabled=(value)
    @disabled = value
  end

  # Why each attached file that could not be unpacked was left as it came,
  # for the report.
  def self.failures
    @failures ||= []
  end

  def self.job(input:, input_name:, **limits, &block)
    ToolJob.open(input, input_name, limits, &block)
  end

  # A private directory for one tool's run, as AlaveteliSandbox::Job is.
  class ToolJob
    # As AlaveteliSandbox::Job's.
    LIMITS = { output_files: 1000, output_bytes: 1024 * 1024 * 1024 }.freeze
    STEP = { timeout: 120, file_size: 512 * 1024 * 1024,
             stdout: 64 * 1024 * 1024, stderr: 64 * 1024 }.freeze
    # All a step sees of the system's programs.
    BIN = '/usr/bin'
    # As a sandboxed step's.
    ENVIRONMENT = {
      'HOME' => '/tmp/home', 'TMPDIR' => '/tmp', 'LANG' => 'C.UTF-8',
      'LC_ALL' => 'C.UTF-8', 'PATH' => '/usr/bin:/bin',
      'OMP_THREAD_LIMIT' => '1'
    }.freeze

    def self.open(input, input_name, limits)
      raise Refused, 'invalid input name' unless input_name.match?(SAFE_NAME)

      Dir.mktmpdir('mail-worker-') do |dir|
        job = new(dir, input_name, LIMITS.merge(limits))
        File.binwrite(job.input, input)
        File.chmod(0o400, job.input)
        begin
          yield job
        rescue Failed, LimitExceeded => e
          AlaveteliSandbox.failures << job.describe(e)
          raise
        end
      end
    end

    def initialize(dir, input_name, limits)
      @dir = dir
      @input_name = input_name
      @limits = limits
      Dir.mkdir(scratch, 0o700)
    end

    def input = File.join(@dir, @input_name)

    def scratch(name = nil)
      path = File.join(@dir, 'scratch')
      return path unless name
      raise Refused, 'invalid scratch name' unless name.match?(SAFE_NAME) &&
                                                   !name.include?('..')

      File.join(path, name)
    end

    # What a tool writes to stderr is any bytes at all; the report is JSON.
    def describe(error)
      if error.is_a?(Failed)
        reason = error.result&.stderr.to_s.lines.first.to_s.dup.
                 force_encoding('UTF-8').scrub('?').strip
      end
      { 'program' => @program.to_s,
        'reason' => [error.message, reason].compact.reject(&:empty?).
                    join(': ')[0, 300] }
    end

    # Runs one tool, and raises as AlaveteliSandbox::Job#run does: Failed
    # for a tool that isn't installed or exits unsuccessfully, TimedOut,
    # and LimitExceeded for too much output of any kind.
    def run(program, *args, **options)
      @program = program
      options = STEP.merge(options)
      raise Refused, "#{program}: disabled" if AlaveteliSandbox.disabled?
      raise Refused, "#{program}: not_allowed" unless PROGRAMS.include?(program)

      path = File.join(BIN, program)
      unless File.file?(path) && File.executable?(path)
        raise Failed, "#{program} is not installed (searched #{BIN})"
      end

      status, timed_out, stderr = spawn(path, args, options)
      audit!(program)
      raise TimedOut, "#{program} timed out" if timed_out

      if File.size(log('stdout')) > options[:stdout]
        raise LimitExceeded, "#{program} wrote too much output"
      end
      if signal(status) == Signal.list['XFSZ']
        raise LimitExceeded, "#{program} wrote a file over its size limit"
      end
      return if status.success?

      raise Failed.new("#{program} failed", Result.new(stderr: stderr))
    end

    # Names of the files in the scratch area, sorted.
    def files
      names = Dir.children(scratch)
      most = @limits[:output_files]
      raise LimitExceeded, "more than #{most} output files" if names.size > most

      total = names.sum do |name|
        stat = File.lstat(File.join(scratch, name))
        unless stat.file? && stat.nlink == 1
          raise Failed, "unexpected output #{name.inspect}"
        end

        stat.size
      end
      if total > @limits[:output_bytes]
        raise LimitExceeded, "outputs exceed #{@limits[:output_bytes]} bytes"
      end

      names.sort
    end

    # The bytes of a file a tool wrote to the top of the scratch area.
    def read(name, max:)
      if name.empty? || name.include?('/') || %w[. ..].include?(name)
        raise Refused, 'invalid output name'
      end

      flags = File::RDONLY | File::NOFOLLOW | File::NONBLOCK
      File.open(File.join(scratch, name), flags) do |file|
        stat = file.stat
        unless stat.file? && stat.nlink == 1
          raise Failed, "#{name} is not a regular file"
        end
        if stat.size > max
          raise LimitExceeded, "#{name} is larger than #{max} bytes"
        end

        file.binmode
        file.read
      end
    rescue Errno::ELOOP
      raise Failed, "#{name} is a symbolic link"
    end

    private

    def log(name) = File.join(@dir, name)

    # The signal that ended the tool. A shell reports a signalled child as
    # exit status 128 + signal, so that counts too.
    def signal(status)
      return status.termsig if status.signaled?

      code = status.exitstatus.to_i
      code - 128 if code > 128 && code < 128 + 65
    end

    # [the tool's status, whether it ran out of time, what it wrote to
    # stderr]. The tool gets its own process group, so that all of it can be
    # killed.
    def spawn(path, args, options)
      pid = Process.spawn(
        ENVIRONMENT.merge(options.fetch(:env, {})), path, *args.map(&:to_s),
        in: File::NULL, out: log('stdout'), err: log('stderr'),
        chdir: scratch, unsetenv_others: true, close_others: true,
        pgroup: true, rlimit_fsize: options[:file_size]
      )
      status = wait(pid, options[:timeout])
      timed_out = status.nil?
      if timed_out
        begin
          Process.kill('KILL', -pid)
        rescue Errno::ESRCH
          # It ended as its time ran out.
          nil
        end
        _, status = Process.waitpid2(pid)
      end
      [status, timed_out, File.binread(log('stderr'), options[:stderr]).to_s]
    end

    def wait(pid, seconds)
      stop = Process.clock_gettime(Process::CLOCK_MONOTONIC) + seconds
      loop do
        _, status = Process.waitpid2(pid, Process::WNOHANG)
        return status if status
        return nil if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= stop

        sleep 0.01
      end
    end

    # As AlaveteliSandbox::Job#audit!: directories and regular files with
    # one link only, and no more files or bytes than the job's limits.
    def audit!(program)
      count = 0
      bytes = 0
      Find.find(scratch) do |path|
        next if path == scratch

        stat = File.lstat(path)
        unless stat.directory? || (stat.file? && stat.nlink == 1)
          raise Failed, "#{program} left an unexpected #{stat.ftype}"
        end

        count += 1
        bytes += stat.size if stat.file?
        if count > @limits[:output_files]
          raise LimitExceeded, "#{program} left an unexpected number of files"
        end
        if bytes > @limits[:output_bytes]
          raise LimitExceeded, "#{program} left an unexpected amount of output"
        end
      end
    end
  end
end

begin
  $LOAD_PATH.unshift(File.expand_path('../lib', __dir__))
  $LOAD_PATH.unshift(File.expand_path('../gems/office_package/lib', __dir__))
  require 'mail_handler/parts'
  require 'mail_handler/report'
  require 'office_package/compound_file'
rescue LoadError, StandardError => e
  SAID.puts "NotLoaded: #{e.class}: #{e.message.to_s.lines.first.to_s[0, 300]}"
  exit 2
end

# Loaded, not run, by the spec of the stand-in above.
return unless $PROGRAM_NAME == __FILE__

begin
  input, scratch, tools, bodies, stored = ARGV
  unless [4, 5].include?(ARGV.size) && File.directory?(scratch) &&
         %w[0 1].include?(tools) && bodies.match?(/\A(all|none|\h{32})\z/)
    raise ArgumentError, 'mail worker arguments are invalid'
  end

  AlaveteliSandbox.disabled = tools == '0'
  bodies = bodies.to_sym if %w[all none].include?(bodies)
  report, files = MailHandler::Report.build(
    File.binread(input), bodies: bodies,
                         stored: stored && File.binread(stored)
  )
  report['unexpanded'] = AlaveteliSandbox.failures
  json, files = MailHandler::Report.written(report, files)
  files.each do |name, bytes|
    File.binwrite(File.join(scratch, name), bytes)
  end
  File.binwrite(File.join(scratch, 'report.json'), json)
rescue MailHandler::ReadRefused => e
  SAID.puts "ReadRefused: #{e.message.to_s.lines.first.to_s[0, 300]}"
  exit 2
rescue StandardError, SystemStackError => e
  SAID.puts "#{e.class}: #{e.message.to_s.lines.first.to_s[0, 300]}"
  exit 2
end
