require 'external_command'

module AttachmentManagement
  # Runs external attachment tools inside an AlaveteliSandbox job (refusing
  # job: nil when the sandbox is required) and raises Failed on non-zero exit.
  module Command
    Failed = Class.new(StandardError)

    MAX_OUTPUT = 128 * 1024 * 1024
    # Address space for LibreOffice, which reserves far more than it uses.
    LIBREOFFICE_MEMORY = 4 * 1024 * 1024 * 1024

    def self.run(program, *args, job:, timeout: 120, env: {})
      return in_job(job, program, args, timeout: timeout, env: env) if job

      if AlaveteliSandbox.required?
        AlaveteliSandbox.log(:not_routed, program)
        raise Failed, "#{program}: refused outside a sandbox job"
      end

      path = find(program)
      command = ExternalCommand.new(path, *args.map(&:to_s),
                                    timeout: timeout,
                                    env: env,
                                    binary_output: true)
      command.run
      unless command.exited && command.status&.zero?
        reason = if command.timed_out
                   "timed out after #{timeout}s"
                 else
                   "exit #{command.status.inspect}"
                 end
        raise Failed, "#{program}: #{reason}#{detail(command.err)}"
      end
      command.out
    rescue ExternalCommand::ChildUnterminated => e
      raise Failed, "#{program}: #{e.message}"
    end

    def self.in_job(job, program, args, timeout:, env:)
      options = { timeout: timeout, env: env, stdout: MAX_OUTPUT }
      if %w[soffice libreoffice].include?(program)
        options[:memory] = LIBREOFFICE_MEMORY
      end
      job.run(program, *args, **options).stdout
    rescue AlaveteliSandbox::Failed => e
      raise Failed, "#{program}: " \
                    "#{e.result ? e.result.status_description : e.message}" \
                    "#{detail(e.result&.stderr)}"
    rescue AlaveteliSandbox::Error => e
      raise Failed, e.message
    end

    def self.detail(stderr)
      text = stderr.to_s.dup.force_encoding('UTF-8').scrub.
             lines.last(3).join.strip
      text.present? ? ": #{text}" : ''
    end

    def self.available?(program)
      find(program).present?
    rescue Failed
      false
    end

    def self.find(program)
      AlaveteliSandbox.program_path(program, sandboxed: false)
    rescue AlaveteliSandbox::Failed => e
      raise Failed, e.message
    end
  end
end
