require 'digest'
require 'json'

module MailHandler
  # Reads an email's body via MailHandler::Report (in-process, bubblewrap or
  # mail cell; see doc/FORK.md). Treats the worker as untrusted: every field,
  # count and size is validated against walk limits before reading, part files
  # are opened without following links, and bytes must match the report digest.
  class Reading
    # Malformed worker report or mismatched part file.
    Invalid = Class.new(StandardError)

    # Stored email file is missing (distinct from an empty mail).
    NoSource = Class.new(StandardError)

    REPORT_MAX_BYTES = Report::MAX_BYTES
    MAX_TOTAL_BYTES = 512 * 1024 * 1024

    # Max output files: parts + up to 2x MAX_UU_BLOCKS (stopping part can add
    # another full batch) + report, stored file and matched block.
    OUTPUT_FILES = MAX_PARTS + (2 * MAX_UU_BLOCKS) + 3

    # Max url_part_number: parts plus uuencoded blocks of one part.
    MAX_NUMBER = MAX_PARTS + MAX_UU_BLOCKS + 1

    REASON_CHARS = 300

    HEXDIGEST = /\A\h{32}\z/

    # Cumulative read-time budget (seconds) for a web request; jobs use the
    # worker limit. With cells, a waiting page caps at ~2x this plus grace.
    PAGE_SECONDS = 15

    # Uuencoded block; numbered from count_first_uudecode_count during parse.
    Block = Struct.new(:content_type, :filename, :hexdigest, :body,
                       keyword_init: true)

    # body is nil for a part whose bytes weren't asked for, and uuencoded for
    # a read that didn't ask for every part's.
    Part = Struct.new(:url_part_number, :content_type, :filename, :charset,
                      :within_rfc822_subject, :hexdigest, :body, :uuencoded,
                      keyword_init: true) do
      # Matches MailHandler.get_attachment_attributes without original_body.
      def attributes
        to_h.except(:uuencoded)
      end
    end

    # matched: original part/block attributes for stored:, or nil.
    # unexpanded: [[program, reason]] for TNEF/Outlook parts left unexpanded.
    attr_reader :parts, :count_first_uudecode_count, :matched, :unexpanded

    # Reads source as binary bytes. bodies: :all, false, or part: hexdigest.
    # stored: matches a stored file to its original part and reads it back.
    # Raises NoSource (missing source), TooComplex (over limits), or
    # ReadRefused (transient/sandbox failure; halts further reads this request).
    def self.of(source, part: nil, bodies: true, stored: nil)
      raise NoSource, 'the email has no source to read' if source.nil?

      source = source.to_s.b
      wanted = if part
                 # No part has a digest that isn't one.
                 part.to_s.match?(HEXDIGEST) ? part : :none
               else
                 bodies && stored.nil? ? :all : :none
               end
      reading = if AlaveteliSandbox.required?
                  within_wait do |timeout|
                    sandboxed(source, wanted, stored, timeout: timeout)
                  end
                else
                  in_process(source, wanted, stored)
                end
      raise TooComplex, reading.too_complex if reading.too_complex

      reading
    end

    def self.for_page?
      ActiveSupport::ExecutionContext.to_h[:controller].present?
    end

    # Yields remaining page seconds (nil outside a page) and deducts elapsed.
    def self.within_wait
      left = page_seconds_left!
      return yield(nil) unless left

      started = clock
      begin
        yield left
      rescue ReadRefused
        Current.mail_read_refused = true
        raise
      ensure
        Current.mail_read_left -= clock - started
      end
    end

    # Whole seconds left for mail reads in a web request, or nil outside one.
    # Raises ReadRefused once exhausted or previously refused; callers check
    # before fetching source bytes.
    def self.page_seconds_left!
      return unless for_page? && AlaveteliSandbox.required?

      if Current.mail_read_refused
        raise ReadRefused, 'a read was refused earlier in this request'
      end

      left = (Current.mail_read_left ||= PAGE_SECONDS.to_f)
      return left.ceil if left.positive?

      Current.mail_read_refused = true
      raise ReadRefused, 'this request has spent its time for reading mail'
    end

    def self.clock
      Process.clock_gettime(Process::CLOCK_MONOTONIC)
    end

    def self.self_test_mail
      message = [File.binread(OUTLOOK_SELF_TEST)].pack('m').gsub("\n", "\r\n")
      ['From: self-test@localhost', 'Subject: Mail read self-test',
       'MIME-Version: 1.0',
       'Content-Type: multipart/mixed; boundary="self-test"', '',
       '--self-test', 'Content-Type: text/plain', '', 'Mail read self-test',
       '--self-test',
       'Content-Type: application/vnd.ms-outlook; name="self-test.msg"',
       'Content-Transfer-Encoding: base64', '',
       "#{message}--self-test--", ''].join("\r\n")
    end

    # Verifies mail reading and msgconvert end-to-end; raises ReadRefused on
    # failure. Clears Current state so prior checks cannot mask this result.
    def self.self_test
      Current.mail_read_refused = nil
      Current.mail_read_left = nil
      parts = of(self_test_mail).parts
      return if parts.first&.body.to_s.include?('Mail read self-test') &&
                parts.any? do |part|
                  part.within_rfc822_subject == 'Converter self-test'
                end

      raise ReadRefused, 'the built-in mail was not read as expected'
    end

    def self.in_process(source, wanted, stored)
      report, files = Report.build(source, bodies: wanted, stored: stored)
      json, files = Report.written(report, files)
      new(JSON.parse(json), wanted, stored: !stored.nil?) do |name, _size|
        files.fetch(name)
      end
    end

    def self.sandboxed(source, wanted, stored, timeout: nil)
      reading = AlaveteliSandbox.job(
        input: source, input_name: 'mail.eml', output_files: OUTPUT_FILES
      ) do |job|
        if stored
          File.binwrite(job.scratch(AlaveteliSandbox::MailStep::STORED),
                        stored)
        end
        job.run_mail_read(bodies: wanted.to_s, stored: !stored.nil?,
                          **{ timeout: timeout }.compact)
        report = JSON.parse(job.read('report.json', max: REPORT_MAX_BYTES))
        new(report, wanted, stored: !stored.nil?) do |name, size|
          job.read(name, max: size)
        end
      end
      reading.unexpanded.each do |program, reason|
        AlaveteliSandbox.log(:failed, program, reason)
      end
      reading
    rescue AlaveteliSandbox::Failed => e
      # The worker says why on the first line it writes.
      said = e.result&.stderr.to_s.lines.first.to_s.strip
      said = e.message if said.empty?
      raise ReadRefused, "the mail worker failed: #{said[0, 300]}"
    rescue AlaveteliSandbox::Error => e
      raise ReadRefused, 'the mail worker could not run: ' \
                         "#{e.class.name.split('::').last}: " \
                         "#{e.message[0, 300]}"
    rescue JSON::ParserError, Invalid => e
      raise ReadRefused, "the mail worker's report can't be used: " \
                         "#{e.message[0, 300]}"
    rescue SystemCallError => e
      # Missing worker output file or full conversion volume.
      raise ReadRefused, "the mail worker's files can't be used: " \
                         "#{e.message[0, 300]}"
    end

    # Validates a parsed worker report and fetches only requested part files;
    # ignores report['matched'] unless stored: is true.
    def initialize(report, wanted = :all, stored: false, &fetch)
      raise Invalid, 'the report is not an object' unless report.is_a?(Hash)

      @fetch = fetch
      @parts = []
      @unexpanded = []
      @total_bytes = 0
      if report.key?('too_complex')
        @too_complex = text(report['too_complex'])[0, REASON_CHARS]
        return
      end

      matched = report['matched'] if stored
      described = list(report['parts'], MAX_PARTS)
      fields = described.map { |part| part_fields(part) }
      read = read_back(fields, wanted, matched)
      @blocks = 0
      @parts = described.each_with_index.map do |part, index|
        build_part(part, index, fields[index],
                   body: read.include?(index), blocks: wanted == :all)
      end
      @count_first_uudecode_count =
        number(report['count_first_uudecode_count'])
      @unexpanded = list(report.fetch('unexpanded', []), MAX_PARTS).
                    map { |entry| unexpanded_entry(entry) }
      @matched = original(matched) if matched
    rescue IndexError, ArgumentError, TypeError, NoMethodError,
           RangeError, EncodingError => e
      raise Invalid, "the report is not as expected (#{e.class})"
    end

    attr_reader :too_complex

    def part_with(hexdigest)
      parts.find { |part| part.hexdigest == hexdigest && part.body }
    end

    private

    def part_fields(described)
      fields = Report::PART_FIELDS.to_h do |name|
        [name, Report.unpack(described.fetch(name.to_s))]
      end
      check(fields)
      fields
    end

    def read_back(fields, wanted, matched)
      indexes = case wanted
                when :all then fields.each_index.to_a
                when :none then []
                else [fields.index { |part| part[:hexdigest] == wanted }]
                end
      if matched.is_a?(Hash) && !matched['uuencoded']
        indexes << whole(matched.fetch('part'))
      end
      indexes.compact
    end

    def build_part(described, index, fields, body:, blocks:)
      part = Part.new(**fields)
      if body
        part.body = bytes(described, Report.part_file(index),
                          fields[:hexdigest])
      end
      return part unless blocks

      part.uuencoded = blocks_of(described, index)
      part
    end

    # Worker stops scanning for uuencoded blocks at MAX_UU_BLOCKS; reject
    # reports that continue searching past that limit.
    def blocks_of(described, index)
      found = described.fetch('uuencoded')
      return if found.nil?
      if @blocks >= MAX_UU_BLOCKS
        raise Invalid, 'a part was searched for blocks past the limit'
      end

      @blocks += found.size if found.is_a?(Array)
      list(found, MAX_UU_BLOCKS).each_with_index.map do |block, number|
        Block.new(**block(block, Report.block_file(index, number)))
      end
    end

    def block(described, file, names = Report::BLOCK_FIELDS)
      fields = names.to_h do |name|
        [name, Report.unpack(described.fetch(name.to_s))]
      end
      check(fields)
      fields.merge(body: bytes(described, file, fields[:hexdigest]))
    end

    def original(described)
      found = @parts.fetch(whole(described.fetch('part')))
      return found.attributes unless described['uuencoded']

      block(described['uuencoded'], Report::MATCHED_FILE,
            Report::BLOCK_FIELDS + [:url_part_number])
    end

    # [the program, why]. Only the worker's own tools can have failed.
    def unexpanded_entry(entry)
      program, reason = entry.values_at('program', 'reason')
      unless AlaveteliSandbox::CELL_PROGRAMS.
             fetch(AlaveteliSandbox::MailStep::CELL).include?(program)
        raise Invalid, 'the report names a program the worker does not run'
      end

      [program, text(reason)[0, REASON_CHARS]]
    end

    def check(fields)
      unless fields[:content_type].is_a?(String) &&
             fields[:hexdigest].is_a?(String) &&
             fields[:hexdigest].match?(HEXDIGEST)
        raise Invalid, 'a part has no content type or digest'
      end

      fields.each do |name, value|
        ok = if name == :url_part_number
               value.is_a?(Integer) && value.between?(0, MAX_NUMBER)
             else
               value.nil? || value.is_a?(String)
             end
        raise Invalid, "a part's #{name} is not as expected" unless ok
      end
    end

    # Enforce per-file and cumulative byte caps before reading, then verify
    # exact size and MD5 digest against the report.
    def bytes(described, file, hexdigest)
      body = described.fetch('body')
      size = whole(body.fetch('bytes'))
      raise Invalid, "#{file} is larger than a part can be" if
        size > AlaveteliSandbox::MailStep::LIMITS.fetch(:file_size)
      raise Invalid, 'the email parts are larger than allowed' if
        (@total_bytes += size) > MAX_TOTAL_BYTES

      encoding = Report.encoding(body.fetch('encoding'))
      data = @fetch.call(file, size)
      unless data.is_a?(String) && data.bytesize == size &&
             Digest::MD5.hexdigest(data) == hexdigest
        raise Invalid, "#{file} is not the part the report describes"
      end

      # An empty file is read as a frozen string.
      (data.frozen? ? data.dup : data).force_encoding(encoding)
    end

    def list(value, most)
      unless value.is_a?(Array) && value.size <= most &&
             value.all?(Hash)
        raise Invalid, 'a list in the report is not as expected'
      end

      value
    end

    def whole(value)
      raise Invalid, 'a number in the report is not as expected' unless
        value.is_a?(Integer) && !value.negative?

      value
    end

    def number(value)
      raise Invalid, 'a number in the report is not as expected' unless
        whole(value) <= MAX_NUMBER

      value
    end

    def text(value)
      raise Invalid, 'text in the report is not as expected' unless
        value.is_a?(String)

      value
    end
  end
end
