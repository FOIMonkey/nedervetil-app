require 'zlib'

# Byte-level Office/zip builders so specs control zip structure and parts.
module OfficeFixtures
  R = 'http://schemas.openxmlformats.org/officeDocument/2006/relationships/'.freeze
  META = 'http://schemas.openxmlformats.org/package/2006/relationships/' \
         'metadata/'.freeze
  MS2011 = 'http://schemas.microsoft.com/office/2011/relationships/'.freeze
  MS2017 = 'http://schemas.microsoft.com/office/2017/10/relationships/'.freeze
  MS2018 = 'http://schemas.microsoft.com/office/2018/10/relationships/'.freeze
  CT = 'application/vnd.openxmlformats-officedocument.'.freeze
  W = 'xmlns:w="http://schemas.openxmlformats.org/wordprocessingml/2006/' \
      'main" xmlns:r="http://schemas.openxmlformats.org/officeDocument/' \
      '2006/relationships"'.freeze
  X = 'xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" ' \
      'xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/' \
      'relationships"'.freeze
  P = 'xmlns:a="http://schemas.openxmlformats.org/drawingml/2006/main" ' \
      'xmlns:p="http://schemas.openxmlformats.org/presentationml/2006/main" ' \
      'xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/' \
      'relationships"'.freeze
  DECLARATION = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'.freeze
  CORE = "#{DECLARATION}<cp:coreProperties xmlns:cp=\"http://schemas." \
         'openxmlformats.org/package/2006/metadata/core-properties" ' \
         'xmlns:dc="http://purl.org/dc/elements/1.1/" ' \
         'xmlns:dcterms="http://purl.org/dc/terms/" ' \
         'xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">' \
         '<dc:title>Fleet report</dc:title>' \
         '<dc:creator>Jane Example</dc:creator>' \
         '<cp:lastModifiedBy>Jane Example</cp:lastModifiedBy>' \
         '<cp:keywords>internal</cp:keywords>' \
         '<dcterms:created xsi:type="dcterms:W3CDTF">2026-01-02T03:04:05Z' \
         '</dcterms:created>' \
         '<dcterms:modified xsi:type="dcterms:W3CDTF">2026-01-03T03:04:05Z' \
         '</dcterms:modified></cp:coreProperties>'.freeze

  module_function

  # entries: [[name, data, options], ...]. Options: method (8 or 0),
  # local_name, flags, descriptor (true writes a signed data descriptor).
  # between: bytes after the first entry. prefix, trailing: bytes before the
  # first entry and after the end record.
  def zip(entries, comment: '', between: '', prefix: '', trailing: '')
    out = prefix.b.dup
    central = +''.b
    entries.each_with_index do |(name, data, options), index|
      options ||= {}
      data = data.b
      method = options.fetch(:method, 8)
      body = method == 8 ? deflate(data) : data
      crc = Zlib.crc32(data)
      flags = options.fetch(:flags, 0)
      flags |= 0x0008 if options[:descriptor]
      local_name = (options[:local_name] || name).b
      offset = out.bytesize
      sizes = if options[:descriptor]
                [0, 0,
                 0]
              else
                [crc, body.bytesize, data.bytesize]
              end
      out << [0x04034b50, 20, flags, method, 0x6000, 0x5C42, *sizes,
              local_name.bytesize, 0].pack('VvvvvvVVVvv')
      out << local_name << body
      if options[:descriptor]
        out << [0x08074b50, crc, body.bytesize, data.bytesize].pack('VVVV')
      end
      out << between.b if index.zero?
      central << [0x02014b50, 20, 20, flags, method, 0x6000, 0x5C42, crc,
                  body.bytesize, data.bytesize, name.b.bytesize, 0, 0, 0, 0,
                  0, offset].pack('VvvvvvvVVVvvvvvVV')
      central << name.b
    end
    directory = out.bytesize
    out << central
    out << [0x06054b50, 0, 0, entries.size, entries.size, central.bytesize,
            directory, comment.b.bytesize].pack('VvvvvVVv')
    out << comment.b << trailing.b
  end

  def deflate(data)
    deflater = Zlib::Deflate.new(6, -Zlib::MAX_WBITS)
    deflater.deflate(data, Zlib::FINISH)
  ensure
    deflater&.close
  end

  def package(files, **options)
    zip(files.map { |name, data| [name, data] }, **options)
  end

  def rels(list)
    items = list.map do |id, type, target, mode|
      mode_attribute = mode ? %( TargetMode="#{mode}") : ''
      %(<Relationship Id="#{id}" Type="#{type}" Target="#{target}") +
        "#{mode_attribute}/>"
    end
    "#{DECLARATION}<Relationships xmlns=\"http://schemas.openxmlformats." \
      "org/package/2006/relationships\">#{items.join}</Relationships>"
  end

  def content_types(overrides, defaults = {})
    defaults = { 'rels' => 'application/vnd.openxmlformats-package.' \
                           'relationships+xml',
                 'xml' => 'application/xml' }.merge(defaults)
    "#{DECLARATION}<Types xmlns=\"http://schemas.openxmlformats.org/" \
      'package/2006/content-types">' +
      defaults.map do |ext, type|
        %(<Default Extension="#{ext}" ContentType="#{type}"/>)
      end.join +
      overrides.map do |part, type|
        %(<Override PartName="/#{part}" ContentType="#{type}"/>)
      end.join + '</Types>'
  end

  # Word OOXML package. parts: { name => [content_type, data] }.
  def word(body, parts: {}, document_rels: [], package_rels: [],
           defaults: {}, core: CORE, **options)
    overrides = { 'word/document.xml' => "#{CT}wordprocessingml.document." \
                                         'main+xml' }
    overrides['docProps/core.xml'] = 'application/vnd.openxmlformats-' \
                                     'package.core-properties+xml' if core
    parts.each { |name, (type, _data)| overrides[name] = type if type }
    files = {
      '[Content_Types].xml' => content_types(overrides, defaults),
      '_rels/.rels' => rels(
        [['rId1', "#{R}officeDocument", 'word/document.xml']] +
        (if core
           [['rId2', "#{META}core-properties",
             'docProps/core.xml']]
         else
           []
         end) +
        package_rels
      ),
      'word/document.xml' => "#{DECLARATION}<w:document #{W}><w:body>" \
                             "#{body}</w:body></w:document>"
    }
    files['word/_rels/document.xml.rels'] = rels(document_rels) if
      document_rels.any?
    files['docProps/core.xml'] = core if core
    parts.each { |name, (_type, data)| files[name] = data }
    package(files, **options)
  end

  # A workbook of one sheet unless sheets says otherwise ({ name => xml }).
  # states: { sheet number => 'hidden' or 'veryHidden' }.
  def workbook(sheets: nil, parts: {}, workbook_rels: [], sheet_rels: {},
               workbook_extra: '', core: CORE, defaults: {}, states: {})
    sheets ||= { 'xl/worksheets/sheet1.xml' => sheet_xml }
    overrides = { 'xl/workbook.xml' => "#{CT}spreadsheetml.sheet.main+xml" }
    sheets.each_key do |name|
      overrides[name] = "#{CT}spreadsheetml.worksheet+xml"
    end
    overrides['docProps/core.xml'] = 'application/vnd.openxmlformats-' \
                                     'package.core-properties+xml' if core
    parts.each { |name, (type, _data)| overrides[name] = type if type }
    listed = sheets.keys.each_with_index.map do |_name, index|
      state = states[index + 1] ? %( state="#{states[index + 1]}") : ''
      %(<sheet name="Sheet#{index + 1}" sheetId="#{index + 1}"#{state} ) +
        %(r:id="rIdS#{index + 1}"/>)
    end.join
    sheet_relationships = sheets.keys.each_with_index.map do |name, index|
      ["rIdS#{index + 1}", "#{R}worksheet", name.delete_prefix('xl/')]
    end
    files = {
      '[Content_Types].xml' => content_types(overrides, defaults),
      '_rels/.rels' => rels(
        [['rId1', "#{R}officeDocument", 'xl/workbook.xml']] +
        (core ? [['rId2', "#{META}core-properties", 'docProps/core.xml']] : [])
      ),
      'xl/workbook.xml' => "#{DECLARATION}<workbook #{X}><sheets>#{listed}" \
                           "</sheets>#{workbook_extra}</workbook>",
      'xl/_rels/workbook.xml.rels' => rels(sheet_relationships + workbook_rels)
    }
    sheets.each do |name, xml|
      files[name] = xml
      if sheet_rels[name]
        dir, base = File.split(name)
        files["#{dir}/_rels/#{base}.rels"] = rels(sheet_rels[name])
      end
    end
    files['docProps/core.xml'] = core if core
    parts.each { |name, (_type, data)| files[name] = data }
    package(files)
  end

  # hidden_rows: row numbers. before: XML ahead of sheetData (cols).
  def sheet_xml(rows = [%w[Depot Vans], %w[North 12]], extra: '', before: '',
                hidden_rows: [])
    data = rows.each_with_index.map do |row, r|
      cells = row.each_with_index.map do |value, c|
        %(<c r="#{('A'.ord + c).chr}#{r + 1}" t="inlineStr"><is><t>) +
          "#{value.encode(xml: :text)}</t></is></c>"
      end.join
      hidden = hidden_rows.include?(r + 1) ? ' hidden="1"' : ''
      %(<row r="#{r + 1}"#{hidden}>#{cells}</row>)
    end.join
    "#{DECLARATION}<worksheet #{X}>#{before}<sheetData>#{data}</sheetData>" \
      "#{extra}</worksheet>"
  end

  def deck(slides:, parts: {}, deck_rels: [], slide_rels: {}, core: nil,
           extra: '')
    overrides = { 'ppt/presentation.xml' => "#{CT}presentationml." \
                                            'presentation.main+xml' }
    slides.each_key { |name| overrides[name] = "#{CT}presentationml.slide+xml" }
    parts.each { |name, (type, _data)| overrides[name] = type if type }
    list = slides.keys.each_with_index.map do |_name, index|
      %(<p:sldId id="#{256 + index}" r:id="rIdS#{index + 1}"/>)
    end.join
    files = {
      '[Content_Types].xml' => content_types(overrides),
      '_rels/.rels' => rels([['rId1', "#{R}officeDocument",
                              'ppt/presentation.xml']]),
      'ppt/presentation.xml' => "#{DECLARATION}<p:presentation #{P}>" \
                                "<p:sldIdLst>#{list}</p:sldIdLst>" \
                                "#{extra}</p:presentation>",
      'ppt/_rels/presentation.xml.rels' => rels(
        slides.keys.each_with_index.map do |name, index|
          ["rIdS#{index + 1}", "#{R}slide", name.delete_prefix('ppt/')]
        end + deck_rels
      )
    }
    slides.each do |name, xml|
      files[name] = xml
      if slide_rels[name]
        dir, base = File.split(name)
        files["#{dir}/_rels/#{base}.rels"] = rels(slide_rels[name])
      end
    end
    files['docProps/core.xml'] = core if core
    parts.each { |name, (_type, data)| files[name] = data }
    package(files)
  end

  # A version 3 compound file of the given streams, all in the root storage.
  # Streams under 4,096 bytes go in the mini stream. scramble: lay each
  # stream's sectors out in reverse order, so its text is never contiguous
  # in the file's bytes.
  def compound(streams, scramble: false)
    free = 0xFFFFFFFF
    chain_end = 0xFFFFFFFE
    sectors = []
    fat = []
    allocate = ->(data, size) do
      chunks = data.b.scan(/.{1,#{size}}/mn)
      chunks = [''.b] if chunks.empty?
      chunks.map { |chunk| chunk.ljust(size, "\0".b) }
    end
    place = ->(chunks, store, table) do
      order = scramble ? chunks.each_index.to_a.reverse : chunks.each_index.to_a
      numbers = Array.new(chunks.size)
      order.each do |index|
        numbers[index] = store.size
        store << chunks[index]
        table << free
      end
      numbers.each_cons(2) { |a, b| table[a] = b }
      table[numbers.last] = chain_end
      numbers.first
    end

    mini = []
    mini_fat = []
    entries = []
    streams.each do |name, data|
      data = data.b
      start = if data.bytesize < 4096
                place.call(allocate.call(data, 64), mini, mini_fat)
              else
                place.call(allocate.call(data, 512), sectors, fat)
              end
      entries << [name, 2, start, data.bytesize]
    end
    mini_stream = mini.join
    mini_start = if mini_stream.empty?
                   chain_end
                 else
                   place.call(allocate.call(mini_stream, 512), sectors, fat)
                 end
    mini_fat_data = mini_fat.pack('V*')
    mini_fat_start = if mini_fat.empty?
                       chain_end
                     else
                       place.call(allocate.call(mini_fat_data, 512), sectors,
                                  fat)
                     end
    mini_fat_count = (mini_fat_data.bytesize / 512.0).ceil

    entry = ->(name, type, child, start, size, right = free) do
      utf16 = "#{name}\0".encode('UTF-16LE').b
      utf16.ljust(64, "\0".b) +
        [utf16.bytesize, type, 1, free, right, child].pack('vCCVVV') +
        ("\0" * 36).b + [start, size, 0].pack('VVV')
    end
    # The streams hang off the root as a chain of right siblings.
    directory = +''.b
    directory << entry.call('Root Entry', 5, entries.empty? ? free : 1,
                            mini_start, mini_stream.bytesize)
    entries.each_with_index do |(name, type, start, size), index|
      right = index + 2 <= entries.size ? index + 2 : free
      directory << entry.call(name, type, free, start, size, right)
    end
    directory << ("\0".b * 128) while (directory.bytesize % 512).positive?
    dir_start = place.call(allocate.call(directory, 512), sectors, fat)

    # The allocation table describes itself too.
    fat_count = ((sectors.size + 1) * 4 / 512.0).ceil
    fat_count = ((sectors.size + fat_count) * 4 / 512.0).ceil
    fat_numbers = (sectors.size...(sectors.size + fat_count)).to_a
    fat_numbers.each { fat << 0xFFFFFFFD }
    table = fat.pack('V*').ljust(fat_count * 512, [free].pack('V') * 128)
    sectors.concat(table.scan(/.{512}/mn))

    difat = fat_numbers + ([free] * (109 - fat_numbers.size))
    header = OfficePackage::COMPOUND_FILE_MAGIC + ("\0" * 16).b +
             [0x3E, 3, 0xFFFE, 9, 6].pack('vvvvv') + ("\0" * 6).b +
             [0, fat_count, dir_start, 0, 4096, mini_fat_start,
              mini_fat_count, chain_end, 0].pack('VVVVVVVVV') +
             difat.pack('V*')
    header + sectors.join
  end

  def parts(bytes)
    found = {}
    Zip::File.open_buffer(StringIO.new(bytes)) do |zip|
      zip.entries.each do |entry|
        found[entry.name] = entry.get_input_stream.read
      end
    end
    found
  end
end
