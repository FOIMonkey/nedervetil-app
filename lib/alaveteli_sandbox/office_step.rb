# Loaded on its own too, by a bare Ruby that reads SOURCE for a cell's unit.
require_relative 'worker_step' unless defined?(AlaveteliSandbox::WorkerStep)

module AlaveteliSandbox
  # Sandbox step definition for script/office_worker.rb (shared by app and
  # Office cell). The worker sees only the input file, scratch, SOURCE files,
  # the Ruby runtime, and its gem dirs, started with --disable-gems.
  # See doc/FORK.md.
  module OfficeStep
    extend WorkerStep

    CELL = 'office'.freeze

    # Every file of the app's the worker loads.
    SOURCE = %w[
      script/office_worker.rb
      gems/office_package/lib/office_package.rb
      gems/office_package/lib/office_package/error.rb
      gems/office_package/lib/office_package/archive.rb
      gems/office_package/lib/office_package/package.rb
      gems/office_package/lib/office_package/compound_file.rb
      gems/office_package/lib/office_package/detector.rb
      gems/office_package/lib/office_package/hidden.rb
      gems/office_package/lib/office_package/writer.rb
      gems/office_package/lib/office_package/tidy.rb
      gems/office_package/lib/office_package/guard.rb
      gems/office_package/lib/office_package/inspector.rb
      gems/office_package/lib/office_package/sheets.rb
      gems/office_package/lib/office_package/excel_metadata.rb
    ].freeze

    # The gems the worker loads. It is also given the gems these need.
    # bigdecimal is named so that the bundle's is given, not Ruby's own.
    GEMS = %w[nokogiri rubyzip bigdecimal].freeze

    # Whatever else the step was given. Memory is address space, for each
    # process.
    LIMITS = {
      timeout: 300,
      memory: 4 * 1024 * 1024 * 1024,
      file_size: 1024 * 1024 * 1024,
      processes: 128,
      tmp_size: 1024 * 1024 * 1024,
      stdout: 64 * 1024,
      stderr: 64 * 1024
    }.freeze

    # What a read may be asked for, run in this order. guard and
    # guard_unpack are OfficePackage::Guard.check! without and with unpack;
    # once one of those asked for fails, nothing else is read, as a caller
    # in the app that guards a file reads nothing of it after that.
    SECTIONS = %w[
      guard guard_unpack inspector hidden content_texts strings sheets excel
      embedded_excel tidy zip_entries
    ].freeze

    # The most each of the sheets section's limits may be: Excel's grid, and
    # OfficePackage::Sheets' own caps on the cells kept and read. max_rows
    # and max_columns may also be nil, for no limit.
    SHEET_LIMITS = {
      max_rows: 1_048_576,
      max_columns: 16_384,
      max_cells: 200_000,
      max_read_cells: 2_000_000
    }.freeze

    # The most each of the zip_entries section's limits may be, matching
    # AttachmentToText's own caps.
    ZIP_LIMITS = {
      max_entries: 500,
      max_entry: 25 * 1024 * 1024,
      max_total: 50 * 1024 * 1024
    }.freeze

    # What the worker leaves in the scratch area: the report, the texts the
    # strings section found, one JSON line each, the file tidy made, when it
    # changed anything, and the extracted bytes of a zip's entries.
    REPORT = 'report.json'.freeze
    STRINGS = 'strings.jsonl'.freeze
    TIDIED = 'tidied'.freeze
    ZIP_ENTRIES = 'zip_entries'.freeze
    EMBEDDED_XLS = 'embedded_xls'.freeze

    # How the worker's stderr begins when the file took more memory than it
    # has: its own line for a NoMemoryError, or Ruby's abort when an
    # allocation fails where it can't raise one.
    TOO_LARGE = /\A(?:TooLarge:|\[FATAL\] failed to allocate memory)/

    module_function

    # The worker's arguments after the file and its scratch area: the
    # sections, in SECTIONS' order, followed by the sheets section's limits
    # and the zip_entries section's limits when those sections are asked for.
    # sections: some of SECTIONS, each once. sheets: for the sheets section
    # only, within SHEET_LIMITS. zip: for the zip_entries section only,
    # within ZIP_LIMITS. Raises ArgumentError for anything else.
    def arguments(sections, sheets, zip = nil)
      unless sections.is_a?(Array) && !sections.empty? &&
             sections.uniq.size == sections.size && (sections - SECTIONS).empty?
        raise ArgumentError,
              "sections must be some of #{SECTIONS.join(', ')}, each once"
      end

      wanted = SECTIONS & sections
      args = [wanted.join(',')]
      args.concat(
        section_limits(wanted, 'sheets', sheets) { sheet_arguments(sheets) }
      )
      args.concat(
        section_limits(wanted, 'zip_entries', zip) { zip_arguments(zip) }
      )
      args
    end

    def section_limits(wanted, section, value)
      return yield if wanted.include?(section)
      return [] if value.nil?

      label = section == 'sheets' ? 'sheet' : 'zip'
      raise ArgumentError, "#{label} limits are for the #{section} section only"
    end

    def sheet_arguments(sheets)
      unless sheets.is_a?(Hash) &&
             sheets.keys.map(&:to_s).sort == SHEET_LIMITS.keys.map(&:to_s).sort
        raise ArgumentError, 'the sheets section needs ' \
                             "#{SHEET_LIMITS.keys.join(', ')}"
      end

      given = sheets.transform_keys(&:to_sym)
      SHEET_LIMITS.map do |name, most|
        sheet_argument(name, given.fetch(name), most)
      end
    end

    def zip_arguments(zip)
      given = zip_hash!(zip)
      args = ZIP_LIMITS.map do |name, most|
        value = given.fetch(name)
        next value.to_s if value.is_a?(Integer) && value.between?(1, most)

        raise ArgumentError, "#{name} must be from 1 to #{most}"
      end
      return args unless given.key?(:skip)

      skip = given[:skip]
      most = ZIP_LIMITS[:max_entries]
      unless skip.is_a?(Integer) && skip.between?(0, most)
        raise ArgumentError, "skip must be from 0 to #{most}"
      end

      skip.positive? ? args + [skip.to_s] : args
    end

    def zip_hash!(zip)
      raise ArgumentError, zip_needs_message unless zip.is_a?(Hash)

      given = zip.transform_keys(&:to_sym)
      extra = given.keys - ZIP_LIMITS.keys - [:skip]
      missing = ZIP_LIMITS.keys - given.keys
      raise ArgumentError, zip_needs_message if extra.any? || missing.any?

      given
    end

    def zip_needs_message
      "the zip_entries section needs #{ZIP_LIMITS.keys.join(', ')}"
    end

    def sheet_argument(name, value, most)
      unlimited = %i[max_rows max_columns].include?(name)
      return 'none' if value.nil? && unlimited
      return value.to_s if value.is_a?(Integer) && value.between?(1, most)

      raise ArgumentError, "#{name} must be from 1 to #{most}" \
                           "#{' or none' if unlimited}"
    end

    def command(bwrap:, input_dir:, scratch_dir:, input_name:, limits:,
                runtime:, ruby:, root:, gem_directories:, sections:, sheets:,
                zip: nil)
      worker_command(
        bwrap: bwrap, input_dir: input_dir, scratch_dir: scratch_dir,
        limits: limits, runtime: runtime, ruby: ruby, root: root,
        gem_directories: gem_directories,
        arguments: [File.join(input_dir, input_name), scratch_dir,
                    *arguments(sections, sheets, zip)]
      )
    end
  end
end
