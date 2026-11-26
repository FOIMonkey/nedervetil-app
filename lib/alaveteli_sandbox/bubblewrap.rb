module AlaveteliSandbox
  ##
  # Builds the bubblewrap command line for one step.
  #
  # The step gets new user, PID, network, IPC, UTS and cgroup namespaces, so it
  # has no network at all, and it can't create further user namespaces. Its
  # filesystem is read-only /usr, a few non-secret configuration paths, fresh
  # /proc, /dev and /tmp, and the job's own input (read-only) and scratch
  # (writable). The environment is replaced entirely.
  #
  # prlimit, inside the sandbox, sets the step's memory (address space), file
  # size, open file, process and CPU limits.
  module Bubblewrap
    PRLIMIT = '/usr/bin/prlimit'.freeze

    LIBREOFFICE_PROGRAMS = %w[soffice libreoffice].freeze
    LIBREOFFICE_PROFILE = '/tmp/.libreoffice'.freeze
    LIBREOFFICE_SETTINGS = File.expand_path(
      'libreoffice-registrymodifications.xcu', __dir__
    )

    # pdftk is Java. Left alone, the JVM sizes its reservations from the
    # machine's memory, which can pass a step's address-space limit and fail
    # it without a word. Inside the sandbox it gets explicit sizes that fit.
    JAVA_PROGRAMS = %w[pdftk].freeze
    JAVA_OPTIONS = '-Xmx1536m -Xss1m -XX:ReservedCodeCacheSize=64m ' \
                   '-XX:CompressedClassSpaceSize=64m ' \
                   '-XX:MaxMetaspaceSize=192m -XX:+UseSerialGC'.freeze
    JAVA_MEMORY = 3 * 1024 * 1024 * 1024

    # Non-secret files programs need, bound read-only when they exist. Add to
    # this only after tracing a failure, one path at a time. Never add /etc as a
    # whole, /run, /srv, home directories, or D-Bus or X11 sockets.
    OPTIONAL_READ_ONLY = %w[
      /etc/alternatives
      /etc/ld.so.cache
      /etc/fonts
      /var/cache/fontconfig
      /etc/libreoffice
      /etc/ImageMagick-6
      /etc/ImageMagick-7
      /etc/java-17-openjdk
      /etc/java-21-openjdk
      /etc/localtime
    ].freeze

    # Debian's merged /usr layout.
    SYMLINKS = {
      '/bin' => 'usr/bin', '/sbin' => 'usr/sbin',
      '/lib' => 'usr/lib', '/lib64' => 'usr/lib64'
    }.freeze

    module_function

    # Sandboxed LibreOffice always gets the step's seeded profile inside the
    # ephemeral /tmp mount, replacing any UserInstallation the caller asked for.
    def libreoffice_args(args)
      args = args.reject { |arg| arg.start_with?('-env:UserInstallation=') }
      ["-env:UserInstallation=file://#{LIBREOFFICE_PROFILE}", *args]
    end

    def argv(bwrap:, input_dir:, scratch_dir:, command:, limits:,
             read_only: [], libreoffice_profile: false,
             seccomp: Seccomp.supported?)
      [
        bwrap,
        '--unshare-all', '--unshare-user', '--disable-userns',
        '--die-with-parent', '--new-session',
        '--info-fd', ProcessRunner::INFO_FD.to_s,
        '--block-fd', ProcessRunner::BLOCK_FD.to_s,
        *(seccomp ? ['--seccomp', ProcessRunner::SECCOMP_FD.to_s] : []),
        '--clearenv',
        '--setenv', 'HOME', '/tmp/home',
        '--setenv', 'TMPDIR', '/tmp',
        '--setenv', 'LANG', 'C.UTF-8',
        '--setenv', 'LC_ALL', 'C.UTF-8',
        '--setenv', 'PATH', '/usr/bin:/bin',
        '--setenv', 'OMP_THREAD_LIMIT', '1',
        *limits.fetch(:env, {}).flat_map do |name, value|
          ['--setenv', name.to_s, value.to_s]
        end,
        '--ro-bind', '/usr', '/usr',
        *read_only.flat_map { |path| ['--ro-bind', path, path] },
        *SYMLINKS.flat_map { |link, target| ['--symlink', target, link] },
        *OPTIONAL_READ_ONLY.flat_map { |path| ['--ro-bind-try', path, path] },
        '--proc', '/proc',
        '--dev', '/dev',
        '--size', limits.fetch(:tmp_size).to_i.to_s, '--tmpfs', '/tmp',
        '--dir', '/tmp/home',
        *(if libreoffice_profile
            ['--dir', LIBREOFFICE_PROFILE,
             '--dir', "#{LIBREOFFICE_PROFILE}/user",
             '--file', ProcessRunner::PROFILE_FD.to_s,
             "#{LIBREOFFICE_PROFILE}/user/registrymodifications.xcu"]
          else
            []
          end),
        # The job's own directories, at their real paths; nothing else of the
        # conversion volume.
        '--ro-bind', input_dir, input_dir,
        '--bind', scratch_dir, scratch_dir,
        '--chdir', scratch_dir,
        '--',
        PRLIMIT,
        "--as=#{limits.fetch(:memory).to_i}",
        "--fsize=#{limits.fetch(:file_size).to_i}",
        "--nofile=#{limits.fetch(:open_files).to_i}",
        "--nproc=#{limits.fetch(:processes).to_i}",
        "--cpu=#{limits.fetch(:timeout).to_i}",
        '--',
        *command
      ]
    end
  end
end
