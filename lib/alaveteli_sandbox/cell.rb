require 'digest'
require 'json'
require 'socket'

module AlaveteliSandbox
  # App client for converter cells (AlaveteliSandbox::CellServer). Sends step
  # metadata as one JSON line over a UNIX socket and reads a JSON header line
  # followed by raw stdout/stderr bytes; the cell builds the bubblewrap command
  # itself. Unreachable or refusing cells fail closed. See doc/FORK.md.
  module Cell
    # A step may wait for a free slot in its cell for as long as its own time
    # limit, then run for that long. This is how much longer to wait for the
    # answer.
    GRACE = 30

    # The most a cell's answer may be, before the step's own output.
    HEADER_BYTES = 64 * 1024
    READ_SIZE = 64 * 1024

    ROOT = File.expand_path('../..', __dir__)

    # The code the app and every cell must share: the sandbox. A worker's own
    # code is named with its step (RedactorStep.release, MailStep.release,
    # OfficeStep.release), so a cell needs only the code of the steps it
    # runs.
    SHARED_CODE = %w[
      lib/alaveteli_sandbox.rb lib/alaveteli_sandbox/**/*
      script/sandbox_cell.rb
    ].freeze

    # What ProcessRunner::Result asks of a Process::Status, from the answer.
    Status = Struct.new(:exitstatus, :termsig) do
      def signaled?
        !termsig.nil?
      end

      def success?
        !signaled? && exitstatus.to_i.zero?
      end
    end

    module_function

    def sockets
      {
        'pdf' => AlaveteliConfiguration.sandbox_pdf_cell.to_s.strip,
        'office' => AlaveteliConfiguration.sandbox_office_cell.to_s.strip,
        'mail' => AlaveteliConfiguration.sandbox_mail_cell.to_s.strip
      }
    end

    def configured?
      sockets.values.any? { |path| !path.empty? }
    end

    # Why the cells' settings can't be used, or nil. All three or none: with
    # only some set, the steps of a cell that isn't would have nowhere to
    # run but this process.
    def configuration_problem
      return unless configured?

      settings = 'SANDBOX_PDF_CELL, SANDBOX_OFFICE_CELL and SANDBOX_MAIL_CELL'
      if sockets.values.any?(&:empty?)
        return "#{settings} must all be set, or none"
      end
      return if AlaveteliSandbox.required?

      "#{settings} need SANDBOX_CONVERTERS: required"
    end

    # Names the release of the code in SHARED_CODE under root, by its
    # content. A cell refuses a step from an app whose release differs, so
    # the two never run different versions of a step.
    def release(root = ROOT)
      @release ||= {}
      @release[root] ||= digest(root, SHARED_CODE)
    end

    # Caches sandbox and worker release digests on first call (at boot) so an
    # on-disk deploy cannot change them under a running process and restarted
    # cells refuse stale app processes.
    def releases
      { 'cells' => release,
        'pdf' => RedactorStep.release,
        'mail' => MailStep.release(ROOT, MailStep.gem_directories),
        'office' => OfficeStep.release(ROOT, OfficeStep.gem_directories) }
    end

    # Names code by its content: the files under root that match the
    # patterns, and any further names (a gem's name and version, say).
    def digest(root, patterns, names = [])
      digest = Digest::SHA256.new
      Dir.glob(patterns, base: root).sort.each do |name|
        path = File.join(root, name)
        digest << name << "\0" << File.binread(path) if File.file?(path)
      end
      names.each { |name| digest << "\0" << name }
      digest.hexdigest[0, 16]
    end

    # Has a cell run one step of the job (the name of its directory on the
    # volume). Returns a ProcessRunner::Result, as running it here would, or
    # raises Refused.
    def run(cell, step, job:, limits:)
      path = sockets[cell].to_s
      raise Refused, 'no converter cell is set for this step' if path.empty?

      request = step.merge('release' => release, 'job' => job,
                           'limits' => limits)
      header, stdout, stderr = ask(path, request, limits)
      if header['error']
        raise Refused, "the #{cell} converter cell refused the step: " \
                       "#{header['error'].to_s[0, 200]}"
      end

      result(header, stdout, stderr)
    rescue SystemCallError, IOError, JSON::ParserError, TypeError,
           ArgumentError => e
      raise Refused, "the #{cell} converter cell is unavailable: " \
                     "#{e.class}: #{e.message[0, 200]}"
    end

    # Sends the request and reads the whole answer, which must come before
    # the deadline and be no more than the step's output limits allow.
    # Returns the parsed first line, stdout and stderr.
    def ask(path, request, limits)
      most = HEADER_BYTES + limits.fetch(:stdout) + limits.fetch(:stderr)
      deadline = monotonic + (2 * limits.fetch(:timeout)) + GRACE
      answer = UNIXSocket.open(path) do |connection|
        connection.write("#{JSON.generate(request)}\n")
        read_all(connection, deadline, most)
      end

      line, output = answer.split("\n", 2)
      output = output.to_s
      header = JSON.parse(line.to_s)
      raise TypeError, 'the answer is not an object' unless header.is_a?(Hash)
      return [header] if header['error']

      sizes = [Integer(header['stdout_size']), Integer(header['stderr_size'])]
      unless sizes.none?(&:negative?) && output.bytesize == sizes.sum
        raise ArgumentError, 'the answer is not the size it says'
      end

      [header, output.byteslice(0, sizes[0]), output.byteslice(sizes[0]..)]
    end

    def read_all(connection, deadline, most)
      answer = +''.b
      loop do
        remaining = deadline - monotonic
        unless remaining.positive? && connection.wait_readable(remaining)
          raise IOError, 'no answer in time'
        end

        chunk = connection.read_nonblock(READ_SIZE, exception: false)
        return answer if chunk.nil?
        next if chunk == :wait_readable

        answer << chunk
        raise ArgumentError, 'the answer is too large' if answer.bytesize > most
      end
    end

    def result(header, stdout, stderr)
      exit_status, signal = header.values_at('exitstatus', 'termsig').
                            map { |value| value.nil? ? nil : Integer(value) }
      ProcessRunner::Result.new(
        status: Status.new(exit_status, signal),
        stdout: stdout, stderr: stderr, info: header['info'].to_s,
        timed_out: header['timed_out'] == true,
        stdout_overflow: header['stdout_overflow'] == true, sandboxed: true,
        namespace_unconfirmed: header['namespace_unconfirmed'] == true,
        outlived: header['outlived'] == true
      )
    end

    def monotonic
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end
  end
end
