module AlaveteliSandbox
  ##
  # What the steps of the app's own Ruby workers share (MailStep,
  # OfficeStep): the worker is a script of the app's, run in bubblewrap by a
  # Ruby started with --disable-gems and given the directories of the gems it
  # loads. A step extends this and names its CELL, SOURCE (the script first,
  # then every other file of the app's the script loads), GEMS and LIMITS.
  module WorkerStep
    # The directories of GEMS and of the gems they need, from this process's
    # bundle: where the app's own Ruby would load them from. For the app, and
    # for the script that prints them for a cell's settings. A cell has no
    # RubyGems and is told them.
    def gem_directories(names = self::GEMS, found = {})
      names.each do |name|
        next if found.key?(name)

        spec = Gem.loaded_specs.fetch(name)
        found[name] = spec.full_require_paths
        gem_directories(spec.runtime_dependencies.map(&:name), found)
      end
      found.values.flatten.uniq
    end

    # Names the worker's code by its content: the files in SOURCE under
    # root, and each gem's name and version. A cell refuses a step from an
    # app whose worker differs from its own, so the two never read a file
    # with different code.
    def release(root, gem_directories)
      @release ||= {}
      @release[[root, gem_directories]] ||=
        Cell.digest(root, self::SOURCE, gem_names(gem_directories))
    end

    # Each gem's name and version, from its directories: the last part of a
    # path that is a name, a hyphen and a version (mail-2.9.1 in
    # .../gems/mail-2.9.1/lib). Where the gems are makes no difference.
    def gem_names(gem_directories)
      gem_directories.map do |dir|
        dir.split('/').reverse.find { |part| part.match?(/.-\d/) } || dir
      end.uniq.sort
    end

    # [the bubblewrap command, the limits it runs under]: the worker's own
    # (LIMITS), whatever the step was given, except that it may be given
    # less time. root is the checkout holding SOURCE, runtime what
    # RedactorStep.runtime returned for ruby, and arguments the worker's.
    def worker_command(bwrap:, input_dir:, scratch_dir:, limits:, runtime:,
                       ruby:, root:, gem_directories:, arguments:)
      limits = limits.merge(
        self::LIMITS,
        timeout: [limits.fetch(:timeout), self::LIMITS[:timeout]].min
      )
      mounts = self::SOURCE.map { |name| File.join(root, name) } +
               gem_directories
      mounts << runtime if runtime.start_with?('/opt/')
      argv = Bubblewrap.argv(
        bwrap: bwrap, input_dir: input_dir, scratch_dir: scratch_dir,
        command: [ruby, '--disable-gems',
                  *gem_directories.flat_map { |dir| ['-I', dir] },
                  File.join(root, self::SOURCE.first), *arguments],
        limits: limits, read_only: mounts
      )
      [argv, limits]
    end
  end
end
