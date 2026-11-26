# Loaded on its own too, by a bare Ruby that reads SOURCE for a cell's unit.
require_relative 'worker_step' unless defined?(AlaveteliSandbox::WorkerStep)

module AlaveteliSandbox
  # Sandbox step definition for script/mail_worker.rb (shared by app and mail
  # cell). The worker sees only the email, scratch, SOURCE files, the Ruby
  # runtime, and its gem dirs, started with --disable-gems. See doc/FORK.md.
  module MailStep
    extend WorkerStep

    CELL = 'mail'.freeze

    # Every file of the app's the worker loads.
    SOURCE = %w[
      script/mail_worker.rb
      lib/mail_handler/parts.rb
      lib/mail_handler/report.rb
      lib/mail_handler/mail_extensions.rb
      lib/alaveteli_file_types.rb
      lib/normalize_string.rb
      gems/office_package/lib/office_package/error.rb
      gems/office_package/lib/office_package/compound_file.rb
    ].freeze

    # The gems the worker loads. It is also given the gems these need.
    GEMS = %w[mail charlock_holmes marcel].freeze

    # Whatever else the step was given. Memory is address space, for each
    # process. A part may be as large as a TNEF file or an Outlook message
    # may unpack to, and the worker unpacks those under /tmp.
    LIMITS = {
      timeout: 300,
      memory: 4 * 1024 * 1024 * 1024,
      file_size: 1024 * 1024 * 1024,
      processes: 128,
      tmp_size: 1024 * 1024 * 1024,
      stdout: 64 * 1024,
      stderr: 64 * 1024
    }.freeze

    # The stored file whose original part is wanted, when there is one, in
    # the scratch area.
    STORED = 'stored'.freeze

    # The parts whose bytes a read may be asked for: all, none, or the part
    # with one digest.
    BODIES = /\A(all|none|\h{32})\z/

    module_function

    # Builds [argv, limits] for script/mail_worker.rb. tools enables tnef and
    # msgconvert (false when CONVERTERS_DISABLED); bodies matches BODIES;
    # stored indicates scratch holds STORED to match.
    def command(bwrap:, input_dir:, scratch_dir:, input_name:, limits:,
                runtime:, ruby:, root:, gem_directories:, tools:, bodies:,
                stored:)
      arguments = [File.join(input_dir, input_name), scratch_dir,
                   tools ? '1' : '0', bodies]
      arguments << File.join(scratch_dir, STORED) if stored
      worker_command(
        bwrap: bwrap, input_dir: input_dir, scratch_dir: scratch_dir,
        limits: limits, runtime: runtime, ruby: ruby, root: root,
        gem_directories: gem_directories, arguments: arguments
      )
    end
  end
end
