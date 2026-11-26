# frozen_string_literal: true

require 'fileutils'
require 'tmpdir'

module PDFRedactor
  # Runs the PDF tools as child processes in a private job directory.
  module LocalTools
    ToolError = Class.new(StandardError)
    Result = Struct.new(:stdout, :stderr, keyword_init: true)

    # A tool that failed, with what it wrote.
    class ToolFailed < ToolError
      attr_reader :result

      def initialize(message, result = nil)
        super(message)
        @result = result
      end
    end

    PROGRAMS = %w[qpdf fix-qdf pdftotext pdftoppm tesseract magick].freeze
    SAFE_NAME = /\A[A-Za-z0-9][A-Za-z0-9._-]{0,127}\z/

    module_function

    def required? = false

    def program_path(name)
      raise ToolError, 'program is not allowed' unless PROGRAMS.include?(name)

      ENV.fetch('PATH').split(File::PATH_SEPARATOR).each do |dir|
        next unless dir.start_with?('/')

        path = File.join(dir, name)
        return path if File.file?(path) && File.executable?(path)
      end
      raise ToolFailed, "#{name} is unavailable"
    end

    def job(input:, input_name:)
      ToolJob.open(input, input_name) { |job| yield job }
    end

    # A private directory with read-only input and a scratch area.
    class ToolJob
      def self.open(input, input_name)
        unless input_name.match?(SAFE_NAME)
          raise ToolError, 'invalid input name'
        end

        Dir.mktmpdir('pdf-redactor-', '/tmp') do |dir|
          job = new(dir, input_name)
          File.binwrite(job.input, input)
          File.chmod(0o400, job.input)
          yield job
        end
      end

      def initialize(dir, input_name)
        @dir = dir
        @input_name = input_name
        @run = 0
        Dir.mkdir(File.join(dir, 'scratch'), 0o700)
      end

      def input = File.join(@dir, @input_name)

      def scratch(name = nil)
        path = File.join(@dir, 'scratch')
        return path unless name

        raise ToolError, 'invalid scratch name' unless name.match?(SAFE_NAME) &&
                                                       !name.include?('..')

        File.join(path, name)
      end

      def run(program, *args, **options)
        path = LocalTools.program_path(program)
        limit = options.fetch(:stdout, 64 * 1024 * 1024)
        @run += 1
        out_path = scratch("stdout-#{@run}")
        err_path = scratch("stderr-#{@run}")
        env = { 'HOME' => '/tmp', 'TMPDIR' => '/tmp',
                'PATH' => '/usr/bin:/bin', 'LANG' => 'C.UTF-8' }.
              merge(options.fetch(:env, {}))
        File.open(out_path, 'wb') do |out|
          File.open(err_path, 'wb') do |err|
            pid = Process.spawn(env, path, *args.map(&:to_s),
                                in: File::NULL, out: out, err: err,
                                chdir: scratch, unsetenv_others: true,
                                close_others: true)
            _, status = Process.waitpid2(pid)
            stdout = File.binread(out_path, limit + 1) || ''.b
            stderr = File.binread(err_path, (64 * 1024) + 1) || ''.b
            if stdout.bytesize > limit || stderr.bytesize > 64 * 1024
              raise ToolError, "#{program} output limit exceeded"
            end

            result = Result.new(stdout: stdout, stderr: stderr)
            unless status.success?
              raise ToolFailed.new("#{program} failed", result)
            end

            result
          end
        end
      ensure
        FileUtils.rm_f(out_path) if out_path
        FileUtils.rm_f(err_path) if err_path
      end
    end
  end
end
