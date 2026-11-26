# frozen_string_literal: true

require 'office_package'
require 'office_package/package'
require 'office_package/compound_file'

module OfficePackage
  ##
  # Counts hidden-data signals in an Excel workbook (.xlsx/.xlsm/.xltx/.xltm)
  # using OfficePackage's hardened ZIP and lazy XML readers, without hydrating
  # every cell into Ruby objects.
  #
  # - Ignores Excel error cells (t="e", such as #REF!, #N/A, #DIV/0!), so a
  #   hidden row or column holding only formula errors isn't counted as filled.
  # - Ignores Excel's built-in defined names (_xlnm.Print_Area, etc.).
  # - Deduplicates overlapping hidden column ranges and clamps to 1..16_384.
  # - EmbeddedScanner inspects /embeddings/* parts (up to depth 2) in any Word,
  #   PowerPoint or Excel package for embedded spreadsheets and legacy .xls
  #   compound files.
  class ExcelMetadata
    MAX_COLUMN = 16_384
    MAX_EMBEDDED_DEPTH = 2
    MAX_EMBEDDED_PACKAGES = 50
    MAX_EMBEDDED_XLS = 10
    MAX_EMBEDDED_TOTAL = 50 * 1024 * 1024
    WORKBOOK_STREAMS = %r{(?:\A|/)(?:Workbook|Book)\z}i
    OLE10_NATIVE_STREAM = %r{(?:\A|/)\x01Ole10Native\z}i
    SPREADSHEET_EXT = /\.(?:xls|xlsx|xlsm|xltx|xltm|xlsb)\z/i
    EMBEDDING_REL_KINDS = %w[package oleobject embeddedobject].freeze
    EMBEDDED_OFFICE_EXT =
      /\.(?:xls|xlsx|xlsm|xltx|xltm|xlsb|docx|docm|pptx|pptm)\z/i
    EMBEDDED_CONTENT_TYPE =
      /spreadsheetml|wordprocessingml|presentationml|ms-excel|ms-word|
       ms-powerpoint|oleobject|ole-storage|vnd\.openxmlformats-package/xi

    def self.call(bytes)
      from_package(OfficePackage.read(bytes))
    end

    def self.from_package(package)
      new(package).to_h
    end

    def self.embedded(bytes, &block)
      if bytes.b.start_with?(COMPOUND_FILE_MAGIC)
        return EmbeddedScanner.new(nil).scan_ole2(bytes, &block)
      end

      embedded_in_package(OfficePackage.read(bytes), &block)
    end

    def self.embedded_in_package(package, &block)
      EmbeddedScanner.new(package).scan(&block)
    end

    def initialize(package)
      @package = package
      @shared = nil
      unless @package.kind == :spreadsheet && @package.main_part
        raise NotPackage, 'not a spreadsheet'
      end

      @workbook_part = @package.main_part
      @workbook_xml = @package.xml(@workbook_part)
    end

    def to_h
      sheets = sheet_counts
      {
        data_model: data_model,
        external_links: external_links,
        hidden_columns: sheets[:hidden_columns],
        hidden_rows: sheets[:hidden_rows],
        hidden_sheets: sheets[:hidden_sheets],
        named_ranges: named_ranges,
        pivot_cache: pivot_cache
      }
    end

    private

    def data_model
      @package.names.count { |name| name.match?(%r{\Axl/model/}i) }
    end

    def external_links
      @workbook_xml.xpath(
        '//*[local-name()="externalReferences"]/' \
        '*[local-name()="externalReference"]'
      ).size
    end

    def pivot_cache
      @workbook_xml.xpath(
        '//*[local-name()="pivotCaches"]/*[local-name()="pivotCache"]'
      ).size
    end

    def named_ranges
      @workbook_xml.xpath(
        '//*[local-name()="definedNames"]/*[local-name()="definedName"]'
      ).count { |node| !node['name'].to_s.start_with?('_xlnm.') }
    end

    def sheet_counts
      totals = { hidden_sheets: 0, hidden_rows: 0, hidden_columns: 0 }
      rels = @package.relationships(@workbook_part).to_h { |rel| [rel.id, rel] }
      seen = Set.new
      sheet_nodes.each do |sheet|
        totals[:hidden_sheets] += 1 if hidden_sheet?(sheet)
        rel = rels[relationship_id(sheet)]
        next unless worksheet_part?(rel) && seen.add?(rel.target)

        add_worksheet_counts(totals, @package.xml(rel.target))
      end
      totals
    end

    def sheet_nodes
      @workbook_xml.xpath('//*[local-name()="sheets"]/*[local-name()="sheet"]')
    end

    def hidden_sheet?(sheet)
      state = sheet['state'].to_s
      !state.empty? && state != 'visible'
    end

    def worksheet_part?(rel)
      rel && rel.kind == 'worksheet' &&
        @package.include?(rel.target) && @package.xml_part?(rel.target)
    end

    def add_worksheet_counts(totals, doc)
      hidden_rows = doc.xpath(
        '//*[local-name()="sheetData"]/*[local-name()="row"]' \
        '[@hidden="1" or @hidden="true"]'
      )
      totals[:hidden_rows] += count_hidden_rows(hidden_rows)
      hidden = hidden_column_map(doc)
      return unless hidden

      rows = doc.xpath('//*[local-name()="sheetData"]/*[local-name()="row"]')
      totals[:hidden_columns] += count_hidden_columns(rows, hidden)
    end

    def count_hidden_rows(rows)
      rows.count do |row|
        row.xpath('./*[local-name()="c"]').any? { |cell| non_empty?(cell) }
      end
    end

    def hidden_column_map(doc)
      ranges = hidden_column_ranges(doc)
      return nil if ranges.empty?

      hidden = Array.new(MAX_COLUMN + 1, false)
      merge_ranges(ranges).each { |first, last| hidden.fill(true, first..last) }
      hidden
    end

    def hidden_column_ranges(doc)
      doc.xpath(
        '//*[local-name()="cols"]/*[local-name()="col"]' \
        '[@hidden="1" or @hidden="true"]'
      ).filter_map do |col|
        first = col['min'].to_i.clamp(1, MAX_COLUMN)
        last = col['max'].to_i.clamp(0, MAX_COLUMN)
        first <= last ? [first, last] : nil
      end
    end

    def merge_ranges(ranges)
      ranges.sort.each_with_object([]) do |(first, last), merged|
        if merged.empty? || first > merged.last[1] + 1
          merged << [first, last]
        elsif last > merged.last[1]
          merged.last[1] = last
        end
      end
    end

    def count_hidden_columns(rows, hidden)
      filled = Set.new
      rows.each { |row| scan_row_columns(row, hidden, filled) }
      filled.size
    end

    def scan_row_columns(row, hidden, filled)
      column = 0
      row.xpath('./*[local-name()="c"]').each do |cell|
        column = cell['r'] ? column_index(cell['r']) : column + 1
        next unless hidden[column]
        next if filled.include?(column)

        filled << column if non_empty?(cell)
      end
    end

    def non_empty?(cell)
      case cell['t']
      when 'e' then false
      when 's'
        raw = cell.at_xpath('./*[local-name()="v"]')&.text
        raw&.match?(/\A\d+\z/) && !shared_strings[raw.to_i].to_s.empty?
      when 'inlineStr'
        !cell.xpath('.//*[local-name()="t"]').map(&:text).join.empty?
      else
        !cell.at_xpath('./*[local-name()="v"]')&.text.to_s.empty?
      end
    end

    def shared_strings
      return @shared if @shared

      rel = @package.related(@workbook_part, 'sharedStrings').first
      @shared = if rel && @package.include?(rel.target)
                  @package.xml(rel.target).
                    xpath('//*[local-name()="si"]').map do |item|
                      item.xpath('./*[local-name()="t"] | ' \
                                 './*[local-name()="r"]/*[local-name()="t"]').
                        map(&:text).join
                    end
                else
                  []
                end
    end

    def relationship_id(node)
      node.attribute_nodes.find do |attribute|
        attribute.name == 'id' &&
          RELATIONSHIPS_NS.include?(attribute.namespace&.href)
      end&.value
    end

    def column_index(reference)
      letters = reference.to_s[/\A[A-Za-z]{1,4}/]
      return 0 unless letters && letters.length <= 3

      letters.upcase.each_char.
        reduce(0) { |sum, char| (sum * 26) + (char.ord - 64) }
    end

    # Walks embedded parts (in /embeddings/, linked by internal embedding
    # relationships, or carrying Office/OLE types) inside any Office package
    # up to MAX_EMBEDDED_DEPTH, probing embedded OOXML spreadsheets (including
    # modern workbooks stored inside OLE2 Package streams) and yielding
    # embedded legacy .xls payloads for LibreOffice conversion.
    class EmbeddedScanner
      def initialize(package)
        @package = package
        @spreadsheets = []
        @errors = []
        @ooxml_count = 0
        @xls_count = 0
        @total_bytes = 0
        @capped = false
      end

      def scan(&block)
        walk(@package, prefix: nil, depth: 0, &block)
        result
      end

      def scan_ole2(bytes, &block)
        inspect_ole2(bytes, 'package', 0, &block)
        result
      end

      private

      def result
        { spreadsheets: @spreadsheets, errors: @errors }
      end

      def stopped?
        @capped || @errors.size >= MAX_EMBEDDED_PACKAGES
      end

      def record_error(part, message)
        return if @errors.size >= MAX_EMBEDDED_PACKAGES

        @errors << { part: part, error: message }
      end

      def walk(package, prefix:, depth:, &block)
        return if stopped?

        parts = candidate_parts(package)
        return if parts.empty?

        if depth >= MAX_EMBEDDED_DEPTH
          record_error(prefix || parts.first,
                       'embedded files nested too deeply')
          return
        end

        parts.each do |part|
          break if stopped?

          full = prefix ? "#{prefix}/#{part}" : part
          inspect_part(package, part, full, depth, &block)
        end
      end

      def candidate_parts(package)
        seen = Set.new
        found = []
        add = ->(part) do
          return if skipped_meta_part?(part)

          found << part if seen.add?(part.downcase)
        end
        package.names.each do |part|
          add.call(part) if embedded_part_name?(package, part)
        end
        relationship_targets(package).each(&add)
        found
      end

      def skipped_meta_part?(part)
        part.nil? || part.match?(%r{\A__MACOSX/}i) ||
          part.match?(%r{(?:\A|/)_rels/}i) || part.casecmp?(CONTENT_TYPES)
      end

      def embedded_part_name?(package, part)
        return true if part.match?(%r{(?:\A|/)embeddings/}i)
        return false if package.xml_part?(part)

        part.match?(EMBEDDED_OFFICE_EXT) ||
          package.content_type(part).to_s.match?(EMBEDDED_CONTENT_TYPE)
      end

      def relationship_targets(package)
        targets = []
        ([''] + package.names).each do |source|
          next if source.match?(%r{\A__MACOSX/}i)

          collect_relationships(package, source, targets)
        end
        targets
      end

      def collect_relationships(package, source, targets)
        package.relationships(source).each do |rel|
          next if rel.external || !package.include?(rel.target)
          next unless embedding_relationship?(package, rel)

          targets << rel.target
        end
      rescue OfficePackage::Error => e
        record_error(package.rels_name(source), e.message)
      end

      def embedding_relationship?(package, rel)
        return true if EMBEDDING_REL_KINDS.include?(rel.kind.downcase)
        return false if package.xml_part?(rel.target)

        package.content_type(rel.target).to_s.match?(EMBEDDED_CONTENT_TYPE)
      end

      def inspect_part(package, part, full, depth, &block)
        data = package.read(part)
        if OfficePackage.package?(data)
          inspect_ooxml(data, full, depth, &block)
        elsif data.b.start_with?(COMPOUND_FILE_MAGIC)
          inspect_ole2(data, full, depth, &block)
        end
      rescue OfficePackage::Error => e
        record_error(full, e.message)
      end

      def inspect_ooxml(data, full, depth, &block)
        if @ooxml_count >= MAX_EMBEDDED_PACKAGES ||
           @total_bytes + data.bytesize > MAX_EMBEDDED_TOTAL
          return cap!(full)
        end

        @ooxml_count += 1
        @total_bytes += data.bytesize
        inner = OfficePackage.read(data)
        if inner.kind == :spreadsheet
          @spreadsheets << { part: full,
                             counts: ExcelMetadata.from_package(inner) }
        end
        walk(inner, prefix: full, depth: depth + 1, &block)
      rescue OfficePackage::Error => e
        record_error(full, e.message)
      end

      def inspect_ole2(data, full, depth, &block)
        return if stopped?

        file = CompoundFile.new(data)
        if file.encrypted?
          record_error(full, 'encrypted Office document')
          return
        end
        yield_legacy_xls(data, full, &block) if workbook_ole2?(file)
        inspect_ole2_streams(file, full, depth, &block)
      rescue OfficePackage::Error => e
        record_error(full, e.message)
      end

      def inspect_ole2_streams(file, full, depth, &block)
        file.streams.each do |stream_path, stream|
          break if stopped?

          target = "#{full}/#{stream_path}"
          if OfficePackage.package?(stream)
            inspect_ooxml(stream, target, depth, &block)
          elsif stream.b.start_with?(COMPOUND_FILE_MAGIC)
            inspect_nested_ole2(stream, target, depth, &block)
          elsif stream_path.match?(OLE10_NATIVE_STREAM)
            inspect_ole10_native(stream, target, depth, &block)
          end
        end
      end

      def inspect_ole10_native(stream, target, depth, &block)
        label, payload = parse_ole10_native(stream.b)
        if payload
          if OfficePackage.package?(payload)
            inspect_ooxml(payload, target, depth, &block)
          elsif payload.start_with?(COMPOUND_FILE_MAGIC)
            inspect_nested_ole2(payload, target, depth, &block)
          end
        elsif label&.match?(EMBEDDED_OFFICE_EXT)
          record_error(target, 'unreadable embedded Office file')
        end
      end

      def parse_ole10_native(data)
        return [nil, nil] if data.bytesize < 10

        _total, flags = data.unpack('Vv')
        return [nil, nil] unless flags == 2

        label, pos = read_cstr(data, 6)
        return [nil, nil] unless label

        _path, pos = read_cstr(data, pos)
        return [label, nil] unless pos && pos + 8 <= data.bytesize

        cmd_len = data.unpack1("@#{pos + 4}V")
        pos += 8 + cmd_len
        return [label, nil] if pos + 4 > data.bytesize

        size = data.unpack1("@#{pos}V")
        pos += 4
        return [label, nil] if size.zero? || pos + size > data.bytesize

        [label, data.byteslice(pos, size)]
      end

      def read_cstr(data, offset)
        return [nil, nil] if offset >= data.bytesize

        nul = data.index("\0".b, offset)
        return [nil, nil] unless nul

        [data.byteslice(offset, nul - offset), nul + 1]
      end

      def inspect_nested_ole2(stream, target, depth, &block)
        if depth + 1 >= MAX_EMBEDDED_DEPTH
          record_error(target, 'embedded files nested too deeply')
          return
        end
        if @ooxml_count >= MAX_EMBEDDED_PACKAGES ||
           @total_bytes + stream.bytesize > MAX_EMBEDDED_TOTAL
          return cap!(target)
        end

        @ooxml_count += 1
        @total_bytes += stream.bytesize
        inspect_ole2(stream, target, depth + 1, &block)
      end

      def workbook_ole2?(file)
        file.streams.any? { |name, _| name.match?(WORKBOOK_STREAMS) }
      end

      def yield_legacy_xls(data, full)
        if @xls_count >= MAX_EMBEDDED_XLS ||
           @total_bytes + data.bytesize > MAX_EMBEDDED_TOTAL
          return cap!(full)
        end

        @xls_count += 1
        @total_bytes += data.bytesize
        yield full, data if block_given?
      end

      def cap!(full)
        return if @capped

        @capped = true
        record_error(full, 'too many embedded spreadsheets')
      end
    end
  end
end
