# frozen_string_literal: true

require 'json'

module OfficePackage
  # Reads Office files via script/office_worker.rb (bubblewrap or Office cell)
  # when SANDBOX_CONVERTERS is required, or in-process when off.
  # See doc/FORK.md.
  module Isolated
    # A one-paragraph Word file, its text a tracked insertion.
    SELF_TEST = File.expand_path('self_test.docx', __dir__)
    SELF_TEST_REPORT = {
      'guard_unpack' => { 'value' => true },
      'inspector' => { 'value' => [{ 'type' => 'tracked_changes',
                                     'count' => 1 }] }
    }.freeze

    # What a reader raised in the worker when it is none of the errors
    # rebuilt from its report (.rebuilt_errors), with the reader's message.
    ReaderError = Class.new(StandardError)

    module_function

    # Yields a read of an Office file (path, bytes, or existing job) for the
    # given OfficeStep::SECTIONS (run in one worker step when sandboxed).
    # sheets: limits per OfficeStep.arguments. read.value(section) returns the
    # reader's result or re-raises its error; read.each_string yields Detector
    # texts in order (single-use).
    def read(sections, path: nil, bytes: nil, job: nil, sheets: nil, &block)
      open_read(sections, source: { path: path, bytes: bytes, job: job },
                          limits: { sheets: sheets }, &block)
    end

    # Yields a zip read with guard and zip_entries enabled. zip accepts
    # max_entries:, max_entry:, and max_total: within OfficeStep::ZIP_LIMITS.
    def read_zip(zip:, path: nil, bytes: nil, job: nil, &block)
      open_read(%w[guard zip_entries],
                source: { path: path, bytes: bytes, job: job },
                limits: { zip: zip }, &block)
    end

    def open_read(sections, source:, limits:, &block)
      path = source[:path]
      bytes = source[:bytes]
      job = source[:job]
      unless AlaveteliSandbox.required?
        return opened(InProcess.new(path: path || job&.input, bytes: bytes,
                                    **limits), &block)
      end
      return opened(InWorker.new(sections, job: job, **limits), &block) if job

      input = bytes || Pathname(path)
      AlaveteliSandbox.job(input: input, input_name: 'office-file') do |own|
        opened(InWorker.new(sections, job: own, **limits), &block)
      end
    end

    def opened(read)
      yield read
    ensure
      read.close
    end

    # The class of an error a reader raised in the worker, by its name, when
    # a read raises it as itself: the readers' own errors, rubyzip's,
    # Nokogiri's and Ruby's. nil for any other.
    def rebuilt_error(name)
      readers = [OfficePackage::Error, Guard::Refused, Sheets::Refused,
                 Zip::Error, Nokogiri::XML::SyntaxError].flat_map do |root|
        [root, *root.descendants]
      end
      found = readers.find { |error| error.name == name }
      found || ruby_error(name)
    end

    # Defined in C, so already loaded: looking it up loads nothing.
    def ruby_error(name)
      return unless name.is_a?(String) &&
                    name.match?(/\A[A-Z]\w*(::[A-Z]\w*)*\z/)
      return unless Object.const_source_location(name) == []

      error = Object.const_get(name)
      error if error.is_a?(Class) && error < StandardError
    rescue NameError
      nil
    end

    # Runs the worker on SELF_TEST to verify sandbox, volume, Ruby, and gems.
    # Raises AlaveteliSandbox::Error on failure (used by health checks).
    def self_test
      report = AlaveteliSandbox.job(input: File.binread(SELF_TEST),
                                    input_name: 'self-test.docx') do |job|
        job.run_office_read(sections: SELF_TEST_REPORT.keys)
        JSON.parse(job.read(AlaveteliSandbox::OfficeStep::REPORT,
                            max: 64 * 1024))
      end
      return if report == SELF_TEST_REPORT

      raise AlaveteliSandbox::Failed,
            'the built-in document was not read as expected'
    rescue AlaveteliSandbox::Failed => e
      # The worker says why on the first line it writes.
      said = e.result&.stderr.to_s.lines.first.to_s.strip
      raise if said.empty?

      raise AlaveteliSandbox::Failed.new(
        "the Office worker failed: #{said[0, 300]}", e.result
      )
    rescue JSON::ParserError, SystemCallError => e
      raise AlaveteliSandbox::Failed,
            "the Office worker's report can't be used: #{e.message[0, 300]}"
    end
  end
end
