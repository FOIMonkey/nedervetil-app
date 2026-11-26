# frozen_string_literal: true

# Reads one Word, Excel or PowerPoint file with OfficePackage's readers, the
# sections it is asked for, and leaves what each gave in the scratch area.
#
# This script runs only inside the sandbox's namespace
# (AlaveteliSandbox::OfficeStep). It has no Rails boot, database access,
# credentials or network, and is given the directories of the gems it loads.
# It loads RubyGems all the same, as Nokogiri needs Gem::Version and
# Gem::Platform.local as it loads.
#
#   ruby --disable-gems -I <each gem directory> script/office_worker.rb \
#     <the file> <the scratch area> <sections> \
#     [<max rows> <max columns> <max cells> <max read cells>] \
#     [<max entries> <max entry> <max total>]
#
# sections: some of SECTIONS, separated by commas. The four sheet limits come
# with the sheets section, and the three zip limits with the zip_entries
# section; max rows and max columns may be none.
#
# report.json holds an answer for each section read: { "value": ... }, or
# { "error": the class's name, "message": ..., and "reason" and "values"
# when the error has them }. Once guard or guard_unpack fails, no other
# section is read: a caller in the app that guards a file reads nothing of
# it once the guard has failed.
# strings leaves strings.jsonl, a line [part, where, text] for each text
# OfficePackage::Detector gives its matcher, in order, tidy leaves the
# tidied file as tidied when its bytes differ from the file's, and
# zip_entries leaves the extracted entries end-to-end in zip_entries.
# report.json is written last.
#
# Otherwise the one line it writes to stderr says why: NotLoaded when it
# could not load its own code, TooLarge when the file took more memory than
# it has, and the error's class for anything else. Ruby's own abort when an
# allocation fails ("[FATAL] failed to allocate memory") reaches stderr too.
# Nothing else does.
require 'rubygems'
require 'json'
require 'tmpdir'

# Where this worker says why it failed. What Ruby code warns of from here on
# is dropped, but not what Ruby itself writes as it aborts.
SAID = STDERR
$stderr = File.open(File::NULL, 'w') if $PROGRAM_NAME == __FILE__

begin
  require 'nokogiri'
  require 'zip'
  $LOAD_PATH.unshift(File.expand_path('../gems/office_package/lib', __dir__))
  require 'office_package'
  require 'office_package/archive'
  require 'office_package/package'
  require 'office_package/compound_file'
  require 'office_package/detector'
  require 'office_package/hidden'
  require 'office_package/writer'
  require 'office_package/tidy'
  require 'office_package/guard'
  require 'office_package/inspector'
  require 'office_package/sheets'
  require 'office_package/excel_metadata'
rescue LoadError, StandardError => e
  SAID.puts "NotLoaded: #{e.class}: #{e.message.to_s.lines.first.to_s[0, 300]}"
  exit 2
end

# The sections, each as the app calls its reader.
module OfficeWorker
  # The file, read once a section needs its bytes, its scratch area, and any
  # section limits.
  Read = Struct.new(:path, :scratch, :sheets, :zip_limits) do
    def bytes
      @bytes ||= File.binread(path)
    end
  end

  READERS = {
    'guard' => ->(read) { OfficePackage::Guard.check!(read.path) },
    'guard_unpack' => ->(read) {
      OfficePackage::Guard.check!(read.path, unpack: true)
    },
    'inspector' => ->(read) { OfficePackage::Inspector.findings(read.path) },
    'hidden' => ->(read) { OfficePackage::Hidden.call(read.bytes).map(&:to_h) },
    'content_texts' => ->(read) {
      OfficePackage::Hidden.new(OfficePackage.read(read.bytes)).content_texts
    },
    'strings' => ->(read) { OfficeWorker.strings(read) },
    'sheets' => ->(read) {
      OfficePackage::Sheets.read_xlsx(read.path, **read.sheets)
    },
    'excel' => ->(read) { OfficePackage::ExcelMetadata.call(read.bytes) },
    'embedded_excel' => ->(read) { OfficeWorker.embedded_excel(read) },
    'tidy' => ->(read) { OfficeWorker.tidy(read) },
    'zip_entries' => ->(read) { OfficeWorker.zip_entries(read) }
  }.freeze
  SECTIONS = READERS.keys.freeze
  GUARDS = %w[guard guard_unpack].freeze

  REPORT = 'report.json'
  STRINGS = 'strings.jsonl'
  TIDIED = 'tidied'
  ZIP_ENTRIES = 'zip_entries'
  EMBEDDED_XLS = 'embedded_xls'
  POSITIVE = /\A[1-9]\d*\z/
  NON_NEGATIVE = /\A\d+\z/
  POSITIVE_OR_NONE = /\A(none|[1-9]\d*)\z/

  module_function

  def report(path, scratch, sections, sheets, zip = nil)
    read = Read.new(path, scratch, sheets, zip)
    guards, readers = (SECTIONS & sections).partition do |section|
      GUARDS.include?(section)
    end
    report = guards.to_h do |section|
      [section, outcome { READERS.fetch(section).call(read) }]
    end
    return report unless report.values.all? { |answer| answer.key?('value') }

    readers.each do |section|
      report[section] = outcome { READERS.fetch(section).call(read) }
    end
    report
  end

  # An error's message is any bytes; the report is JSON.
  def outcome
    { 'value' => yield }
  rescue StandardError => e
    answer = { 'error' => e.class.name,
               'message' => e.message.dup.force_encoding('UTF-8').scrub }
    answer['reason'] = e.reason if e.respond_to?(:reason)
    answer['values'] = e.values if e.respond_to?(:values)
    answer
  end

  # The matcher answers yes to every text, so the Detector gives a Hit for
  # each, in the order it gave the texts, labelled as the app's Detector
  # labels it (a nested file's parts under its name). The texts wait in
  # /tmp until then, so strings.jsonl is only ever whole.
  def strings(read)
    Dir.mktmpdir('office-worker-') do |dir|
      texts = File.join(dir, 'texts')
      result = File.open(texts, 'w') do |file|
        matcher = ->(text) {
          file.puts(JSON.generate(text))
          true
        }
        OfficePackage::Detector.call(read.bytes, matcher)
      end
      File.open(texts) do |file|
        File.open(File.join(read.scratch, STRINGS), 'w') do |out|
          result.hits.each do |hit|
            text = JSON.parse(file.gets)
            out.puts(JSON.generate([hit.part, hit.where, text]))
          end
        end
      end
      { 'not_checked' => result.not_checked }
    end
  end

  # Tidy can rewrite a file it removed nothing from.
  def tidy(read)
    result = OfficePackage::Tidy.call(read.bytes)
    if result.changed? || result.bytes.b != read.bytes.b
      File.binwrite(File.join(read.scratch, TIDIED), result.bytes)
    end
    { 'changed' => result.changed?, 'removed' => result.removed,
      'kept' => result.kept }
  end

  # Writes each readable entry's bytes end-to-end in zip_entries and returns
  # their names, offsets and sizes, plus how many file entries were seen.
  def zip_entries(read)
    entries = []
    positions = []
    skipped = []
    offset = 0
    target = File.join(read.scratch, ZIP_ENTRIES)
    seen = File.open(target, 'wb') do |out|
      OfficePackage::Guard.each_entry(
        read.path, **read.zip_limits, positions: positions, skipped: skipped
      ) do |name, body|
        out.write(body)
        size = body.bytesize
        entries << { 'name' => name.dup.force_encoding('UTF-8').scrub,
                     'offset' => offset, 'size' => size,
                     'index' => positions.last }
        offset += size
      end
    end
    { 'entries' => entries, 'seen' => seen,
      'skipped' => skipped.map { |n| n.dup.force_encoding('UTF-8').scrub } }
  rescue StandardError
    FileUtils.rm_f(target)
    raise
  end

  # Inspects /embeddings/* in a Word, PowerPoint or Excel file. Embedded OOXML
  # spreadsheets are counted directly; embedded legacy .xls payloads are written
  # end-to-end in embedded_xls so the caller can convert them with LibreOffice.
  def embedded_excel(read)
    legacy = []
    offset = 0
    target = File.join(read.scratch, EMBEDDED_XLS)
    result = File.open(target, 'wb') do |out|
      OfficePackage::ExcelMetadata.embedded(read.bytes) do |part, body|
        out.write(body)
        size = body.bytesize
        legacy << { 'part' => part.dup.force_encoding('UTF-8').scrub,
                    'offset' => offset, 'size' => size }
        offset += size
      end
    end
    FileUtils.rm_f(target) if legacy.empty?
    { 'spreadsheets' => result[:spreadsheets],
      'errors' => result[:errors],
      'legacy_xls' => legacy }
  rescue StandardError
    FileUtils.rm_f(target)
    raise
  end

  def parse_arguments(argv)
    path, scratch, sections_arg, *limits = argv
    sections = sections_arg.to_s.split(',')
    sheets_on = sections.include?('sheets')
    zip_on = sections.include?('zip_entries')
    base = (sheets_on ? 4 : 0) + (zip_on ? 3 : 0)
    allowed = zip_on ? [base, base + 1] : [base]
    unless valid_arguments?(path, scratch, sections, limits, allowed)
      raise ArgumentError, 'office worker arguments are invalid'
    end

    sheets = sheets_on ? parse_sheets(limits.shift(4)) : nil
    zip = zip_on ? parse_zip(limits) : nil
    [path, scratch, sections, sheets, zip]
  end

  def valid_arguments?(path, scratch, sections, limits, allowed)
    File.file?(path.to_s) && File.directory?(scratch.to_s) &&
      !sections.empty? && sections.uniq == sections &&
      (sections - SECTIONS).empty? && allowed.include?(limits.size)
  end

  def parse_sheets(limits)
    unless limits.first(2).all? { |limit| limit.match?(POSITIVE_OR_NONE) } &&
           limits.drop(2).all? { |limit| limit.match?(POSITIVE) }
      raise ArgumentError, 'office worker arguments are invalid'
    end

    %i[max_rows max_columns max_cells max_read_cells].zip(limits).to_h do |k, v|
      [k, v == 'none' ? nil : Integer(v)]
    end
  end

  def parse_zip(limits)
    core = limits.first(3)
    skip = limits[3]
    unless core.all? { |limit| limit.match?(POSITIVE) } &&
           (skip.nil? || skip.match?(NON_NEGATIVE))
      raise ArgumentError, 'office worker arguments are invalid'
    end

    parsed = %i[max_entries max_entry max_total].zip(core).to_h do |k, v|
      [k, Integer(v)]
    end
    parsed[:skip] = Integer(skip) if skip
    parsed
  end
end

# Loaded, not run, by the spec of SOURCE.
return unless $PROGRAM_NAME == __FILE__

begin
  path, scratch, sections, sheets, zip = OfficeWorker.parse_arguments(ARGV)
  report = OfficeWorker.report(path, scratch, sections, sheets, zip)
  File.binwrite(File.join(scratch, OfficeWorker::REPORT),
                JSON.generate(report))
rescue NoMemoryError
  # A literal, as this may have no memory to build a string with.
  SAID.puts 'TooLarge: NoMemoryError'
  exit 2
rescue StandardError, SystemStackError => e
  SAID.puts "#{e.class}: #{e.message.to_s.lines.first.to_s[0, 300]}"
  exit 2
end
