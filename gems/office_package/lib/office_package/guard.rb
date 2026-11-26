# frozen_string_literal: true

require 'zip'
require 'office_package'
require 'office_package/archive'

module OfficePackage
  # Office Open XML files are ZIP archives. They are checked from the central
  # directory before anything parses or converts them, so a zip bomb or a file
  # of thousands of parts is refused, not unpacked. Parts are read through
  # .read, which stops at the size the archive declares, so a header that
  # understates a part can't get past the limits.
  #
  # A refusal names its reason and the values a message about it shows, and
  # AttachmentManagement::ZipGuard words it for the site.
  module Guard
    # reason: a string, such as "sheets"; values: such as { count: 200 }.
    class Refused < StandardError
      attr_reader :reason, :values

      def initialize(reason, **values)
        @reason = reason
        @values = values
        super(reason)
      end
    end

    MAX_SHEETS = 200
    MAX_SLIDES = 500
    XML_PART = /\.(?:xml|rels|vml)\z/i
    CHUNK = 64 * 1024

    module_function

    # unpack: also inflate every part to check it holds no more than declared,
    # for LibreOffice, which reads the archive itself. Zip::Error (not a ZIP) is
    # left to the caller.
    def check!(path, unpack: false)
      if unpack
        if File.size(path) > MAX_TOTAL + (1024 * 1024)
          raise Refused.new('unpacked', size: MAX_TOTAL)
        end

        begin
          Archive.new(File.binread(path))
        rescue OfficePackage::Refused => e
          raise Refused.new('archive', message: e.message)
        end
      end
      count = count!(path)
      zip = open_zip!(path)
      entries = zip.entries
      # Two parts with one name would leave a reader free to unpack the one not
      # checked here.
      raise Refused, 'listed_twice' unless entries.size == count

      sizes!(entries)
      if parts(zip, %r{\Axl/worksheets/[^/]+\.xml\z}i,
               'xl/workbook.xml', 'sheet') > MAX_SHEETS
        raise Refused.new('sheets', count: MAX_SHEETS)
      end
      if parts(zip, %r{\Appt/slides/[^/]+\.xml\z}i,
               'ppt/presentation.xml', 'sldId') > MAX_SLIDES
        raise Refused.new('slides', count: MAX_SLIDES)
      end

      entries.each { |entry| unpack!(entry) } if unpack
      true
    end

    # Yields [name, bytes] for each readable file entry within the remaining
    # entry and byte budgets, returning the count of file entries seen
    # (including skipped ones, up to max_entries). Unreadable entries (such as
    # password-protected ones) are skipped so the rest of the archive is still
    # read; if `skipped` (an Array) is given, skipped entry names are appended
    # (capped at MAX_ENTRIES) so callers can fail closed on sensitive skips.
    def each_entry(path, max_entries:, max_entry:, max_total:, **options)
      skip, positions, skipped = options.values_at(:skip, :positions, :skipped)
      seen = bytes_read = 0
      file_index = -1
      Zip::File.open(path) do |zip_file|
        zip_file.each do |entry|
          next unless entry.file?
          next if (file_index += 1) < (skip || 0)

          if seen >= max_entries || bytes_read >= max_total
            break unless skipped

            record_skipped(skipped, entry)
            next
          end
          seen += 1
          body = read_entry(entry, [max_entry, max_total - bytes_read].min)
          next record_skipped(skipped, entry) unless body

          bytes_read += body.bytesize
          positions << file_index if positions
          yield entry.to_s, body
        end
      end
      seen
    end

    def record_skipped(skipped, entry)
      skipped << entry.to_s if skipped && skipped.size < MAX_ENTRIES
    end

    def read_entry(entry, limit)
      size = entry.size.to_i
      return nil if size.negative? || size > limit

      body = entry.get_input_stream.read(limit + 1)
      return nil if body.nil? || body.bytesize > limit

      body
    rescue StandardError
      nil
    end

    # From the end of the archive alone, before rubyzip reads every entry into
    # memory.
    # source: a path, or an IO over the bytes.
    def count!(source)
      count = count_entries!(source)
      raise Refused.new('parts', count: MAX_ENTRIES) if count > MAX_ENTRIES

      count
    end

    def open_zip!(path)
      Zip::File.new(path)
    rescue NoMethodError, TypeError, ArgumentError => e
      raise Zip::Error, "malformed zip: #{e.message}"
    end

    def count_entries!(source)
      Zip::File.count_entries(source)
    rescue NoMethodError, TypeError, ArgumentError => e
      raise Zip::Error, "malformed zip: #{e.message}"
    end

    def read(entry, limit = MAX_PART)
      size = entry.size.to_i
      raise Refused.new('part_size', size: limit) if size > limit

      data = entry.get_input_stream { |stream| stream.read(size + 1) }.to_s
      raise Refused, 'part_larger' if data.bytesize > size

      data
    end

    def sizes!(entries)
      total = 0
      entries.each do |entry|
        size = entry.size.to_i
        total += size
        raise Refused.new('unpacked', size: MAX_TOTAL) if total > MAX_TOTAL

        if size > MAX_PART && entry.name.match?(XML_PART)
          raise Refused.new('part_size', size: MAX_PART)
        end
        if size > RATIO_FROM && size > entry.compressed_size.to_i * MAX_RATIO
          raise Refused.new('ratio', ratio: MAX_RATIO)
        end
      end
    end

    # Parts by name, or entries in the main part's list (which can name one
    # part many times).
    def parts(zip, pattern, main, element)
      named = zip.entries.count { |entry| entry.name.match?(pattern) }
      entries = zip.entries.select { |entry| entry.name.casecmp?(main) }
      raise Refused, 'listed_twice' if entries.size > 1
      return named if entries.empty?

      listed = parse_xml(read(entries.first)).
               xpath("count(//*[local-name()=\"#{element}\"])").to_i
      [named, listed].max
    end

    def parse_xml(data)
      raise Refused, 'doctype' if OfficePackage.doctype?(data)

      doc = Nokogiri::XML(data) { |config| config.strict.nonet }
      raise Refused, 'doctype' if doc.internal_subset

      doc
    rescue Nokogiri::XML::SyntaxError
      raise Refused, 'not_well_formed'
    end

    def unpack!(entry)
      return if entry.directory?

      size = entry.size.to_i
      unpacked = 0
      entry.get_input_stream do |stream|
        while (chunk = stream.sysread(CHUNK))
          unpacked += chunk.bytesize
          raise Refused, 'part_larger' if unpacked > size
        end
      end
    end
  end
end
