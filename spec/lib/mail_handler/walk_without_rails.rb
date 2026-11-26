# frozen_string_literal: true

# Subprocess driver for parts_without_rails_spec.rb (run with --disable-gems).
# Walks every .eml in ARGV[0] without Rails and prints results + loaded files.
require 'fileutils'
require 'json'
require 'tmpdir'

require 'mail_handler/parts'
require 'office_package/compound_file'
require_relative '../../support/mail_parts_description'

# Minimal AlaveteliSandbox stub running tnef/msgconvert as child processes.
module AlaveteliSandbox
  Error = Class.new(StandardError)
  Refused = Class.new(Error)
  TimedOut = Class.new(Error)
  LimitExceeded = Class.new(Error)

  class Failed < Error
    attr_reader :result

    def initialize(message, result = nil)
      super(message)
      @result = result
    end
  end

  Result = Struct.new(:stderr)

  def self.job(input:, input_name:, **)
    Dir.mktmpdir('walk-') do |dir|
      job = ToolJob.new(dir, input_name)
      File.binwrite(job.input, input)
      yield job
    end
  end

  class ToolJob
    def initialize(dir, input_name)
      @dir = dir
      @input_name = input_name
      Dir.mkdir(scratch)
    end

    def input = File.join(@dir, @input_name)

    def scratch(name = nil) = File.join(*[@dir, 'scratch', name].compact)

    def run(program, *args, **)
      errors = File.join(@dir, 'stderr')
      done = system(program, *args.map(&:to_s), chdir: scratch,
                                                in: File::NULL,
                                                out: File::NULL, err: errors)
      return if done

      raise Failed.new("#{program} failed", Result.new(File.read(errors)))
    end

    def files = Dir.children(scratch).sort

    def read(name, max:) = File.binread(scratch(name), max)
  end
end

root = File.expand_path('../../..', __dir__)
fixtures = Dir[File.join(ARGV.fetch(0), '*.eml')].to_h do |path|
  description = MailPartsDescription.of(File.binread(path)) do |raw|
    MailHandler.mail_from_source(raw)
  end
  [File.basename(path), description]
end

puts JSON.generate(
  'fixtures' => fixtures,
  'loaded' => $LOADED_FEATURES.filter_map do |file|
    file.delete_prefix("#{root}/") if file.start_with?("#{root}/")
  end,
  'rails' => %w[
    Rails ActiveSupport ActionMailbox Nokogiri Bundler Gem
  ].select { |name| Object.const_defined?(name) }
)
