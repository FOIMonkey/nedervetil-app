# frozen_string_literal: true

require 'json'

module OfficePackage
  module Isolated
    # Runs requested OfficeStep sections in one worker step on first access
    # (extra sections run in their own step), rebuilding reader errors from
    # the report and mapping worker OOM to reader limit errors (#too_large).
    # The worker is untrusted: files open via Job and malformed reports raise
    # AlaveteliSandbox::Failed. See doc/FORK.md.
    class InWorker
      include ReportChecks

      MAX_BYTES = AlaveteliSandbox::OfficeStep::LIMITS.fetch(:file_size)
      GUARDS = %w[guard guard_unpack].freeze

      attr_reader :last_zip_index

      def initialize(sections, job:, sheets: nil, zip: nil)
        @pending = sections
        @job = job
        @sheets = sheets
        @zip = zip
        @values = {}
        @errors = {}
      end

      def value(section)
        run(section) unless @values.key?(section) || @errors.key?(section)
        raise @errors[section] if @errors.key?(section)

        @values.fetch(section)
      end

      def each_string(&block)
        value('strings')
        strings(&block)
        nil
      ensure
        discard(AlaveteliSandbox::OfficeStep::STRINGS)
      end

      def each_zip_entry(&block)
        manifest = value('zip_entries')
        slice_stream(
          AlaveteliSandbox::OfficeStep::ZIP_ENTRIES,
          max: AlaveteliSandbox::OfficeStep::ZIP_LIMITS.fetch(:max_total),
          entries: manifest.fetch(:entries), label_key: :name, &block
        )
        manifest.fetch(:seen)
      ensure
        discard(AlaveteliSandbox::OfficeStep::ZIP_ENTRIES)
      end

      def zip_skipped
        value('zip_entries').fetch(:skipped)
      end

      def each_embedded_xls(&block)
        entries = value('embedded_excel').fetch(:legacy_xls)
        return nil if entries.empty?

        slice_stream(
          AlaveteliSandbox::OfficeStep::EMBEDDED_XLS,
          max: ExcelMetadata::MAX_EMBEDDED_TOTAL,
          entries: entries, label_key: :part, &block
        )
        nil
      ensure
        discard(AlaveteliSandbox::OfficeStep::EMBEDDED_XLS)
      end

      def close; end

      private

      def run(section)
        sections = @pending.include?(section) ? @pending : [section]
        @pending -= sections
        begin
          @job.run_office_read(
            sections: sections,
            sheets: (@sheets if sections.include?('sheets')),
            zip: (@zip if sections.include?('zip_entries'))
          )
        rescue AlaveteliSandbox::Failed => e
          raise unless e.result&.stderr.to_s.
                       match?(AlaveteliSandbox::OfficeStep::TOO_LARGE)

          sections.each { |name| @errors[name] = too_large(name) }
          return
        end
        answer(sections, report)
      end

      def report
        json = @job.read(AlaveteliSandbox::OfficeStep::REPORT, max: MAX_BYTES)
        discard(AlaveteliSandbox::OfficeStep::REPORT)
        report = JSON.parse(json)
        raise TypeError, 'the report is not an object' unless report.is_a?(Hash)

        report
      rescue JSON::ParserError, TypeError, SystemCallError => e
        unusable!(e)
      end

      # Once a guard has failed the worker reads nothing else, and nor would
      # the app: what wasn't read raises that guard's error.
      def answer(sections, report)
        sections.each do |name|
          given = report[name] or next
          raise TypeError, "#{name} is not an answer" unless given.is_a?(Hash)

          if given.key?('error')
            @errors[name] = rebuilt(given)
          else
            @values[name] = decoded(name, given.fetch('value'))
          end
        end
        refused(sections)
        return if sections.all? { |name| answered?(name) }

        raise TypeError, 'the report leaves a section unanswered'
      rescue KeyError, TypeError, ArgumentError, NoMethodError => e
        unusable!(e)
      end

      def refused(sections)
        refusal = @errors.values_at(*GUARDS).compact.first or return

        sections.each do |name|
          @errors[name] = refusal unless answered?(name)
        end
      end

      def answered?(name)
        @values.key?(name) || @errors.key?(name)
      end

      def decoded(name, value)
        return guard_passed?(name, value) if GUARDS.include?(name)

        case name
        when 'inspector', 'sheets' then list(value).map { |item| symbols(item) }
        when 'hidden'
          list(value).map { |item| Hidden::Item.new(**symbols(item)) }
        when 'content_texts' then texts(value)
        when 'excel' then excel_counts(value)
        when 'strings' then symbols(value)
        else decode_structured(name, value)
        end
      end

      def decode_structured(name, value)
        case name
        when 'embedded_excel' then embedded_excel_manifest(symbols(value))
        when 'tidy' then tidied(symbols(value))
        when 'zip_entries' then zip_manifest(symbols(value))
        end
      end

      def guard_passed?(name, value)
        raise TypeError, "#{name} did not pass" unless value == true

        true
      end

      def slice_stream(name, max:, entries:, label_key:)
        @job.open_file(@job.scratch(name), max: max) do |file|
          total = file.stat.size
          entries.each do |entry|
            @last_zip_index = entry[:index] if label_key == :name
            yield entry.fetch(label_key), read_slice(file, entry, total)
          end
        end
      rescue SystemCallError, TypeError => e
        unusable!(e)
      end

      def read_slice(file, entry, total)
        offset = entry.fetch(:offset)
        size = entry.fetch(:size)
        raise TypeError, 'slice out of bounds' if offset + size > total

        file.seek(offset)
        body = size.zero? ? +''.b : file.read(size)
        raise TypeError, 'short slice' unless body && body.bytesize == size

        body
      end

      def tidied(value)
        changed = value.fetch(:changed)
        unless [true, false].include?(changed)
          raise TypeError, 'tidy did not say whether it changed the file'
        end

        unless @job.exist?(AlaveteliSandbox::OfficeStep::TIDIED)
          raise TypeError, 'tidy left no output' if changed

          return File.binread(@job.input)
        end

        bytes = @job.read(AlaveteliSandbox::OfficeStep::TIDIED, max: MAX_BYTES)
        discard(AlaveteliSandbox::OfficeStep::TIDIED)
        bytes
      end

      # The reader's error as the app's reader raises it, with its message,
      # reason and values. One the app doesn't rebuild is a ReaderError with
      # the reader's message.
      def rebuilt(given)
        message = given.fetch('message')
        raise TypeError, 'the message is not text' unless message.is_a?(String)

        error_class = Isolated.rebuilt_error(given.fetch('error'))
        return ReaderError.new(message) unless error_class

        if error_class <= Guard::Refused
          error_class.new(given.fetch('reason'),
                          **symbols(given.fetch('values', {})))
        elsif error_class <= Sheets::Refused
          error_class.new(given.fetch('reason'))
        else
          with_message(error_class, message)
        end
      end

      # Some of these take other arguments than a message, or make their
      # message from fields the report doesn't carry.
      def with_message(error_class, message)
        error = error_class.allocate
        StandardError.instance_method(:initialize).bind_call(error, message)
        error.define_singleton_method(:message) { message }
        error.define_singleton_method(:to_s) { message }
        error
      end

      # What each reader raises for a file over its own limits.
      def too_large(name)
        case name
        when 'guard', 'guard_unpack'
          Guard::Refused.new('unpacked', size: MAX_TOTAL)
        when 'sheets' then Sheets::Refused.new('too_large_to_read')
        else Refused.new('a part over the size limit')
        end
      end

      def strings
        @job.open_file(@job.scratch(AlaveteliSandbox::OfficeStep::STRINGS),
                       max: MAX_BYTES) do |file|
          file.each_line { |line| yield text(line) }
        end
      rescue SystemCallError => e
        unusable!(e)
      end

      def text(line)
        part, where, text = JSON.parse(line)
        unless part.is_a?(String) && where.is_a?(String) && text.is_a?(String)
          raise TypeError, 'a line of texts is not as expected'
        end

        text
      rescue JSON::ParserError, TypeError => e
        unusable!(e)
      end

      def list(value)
        raise TypeError, 'not a list' unless value.is_a?(Array)

        value
      end

      def texts(value)
        raise TypeError, 'not a list of texts' unless list(value).all?(String)

        value
      end

      def symbols(value)
        raise TypeError, 'not an object' unless value.is_a?(Hash)

        value.transform_keys(&:to_sym)
      end

      def discard(name)
        File.unlink(@job.scratch(name))
      rescue Errno::ENOENT
        nil
      end

      def unusable!(error)
        raise AlaveteliSandbox::Failed,
              "the Office worker's report can't be used: " \
              "#{error.message.to_s[0, 300]}"
      end
    end
  end
end
