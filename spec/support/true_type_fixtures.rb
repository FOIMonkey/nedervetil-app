# Small, invented sfnt/cmap programs; no third-party or user font files.
module TrueTypeFixtures
  # Only the cmap is needed by the text decoder. Codes have no familiar
  # glyph names or ToUnicode map, so this exercises the embedded fallback.
  def embedded_font_pdf(data)
    content = 'BT /F1 12 Tf 72 700 Td <41> Tj ET'
    objects = [
      '<< /Type /Catalog /Pages 2 0 R >>',
      '<< /Type /Pages /Kids [3 0 R] /Count 1 >>',
      '<< /Type /Page /Parent 2 0 R /MediaBox [0 0 595 842] ' \
      '/Resources << /Font << /F1 4 0 R >> >> /Contents 5 0 R >>',
      '<< /Type /Font /Subtype /TrueType /BaseFont /FixtureSymbol ' \
      '/FontDescriptor 6 0 R >>',
      "<< /Length #{content.bytesize} >>\nstream\n#{content}\nendstream",
      '<< /Type /FontDescriptor /FontName /FixtureSymbol /Flags 4 ' \
      '/FontFile2 7 0 R >>',
      "<< /Length #{data.bytesize} >>\nstream\n#{data}\nendstream".b
    ]
    AttachmentFixtures.write(objects, root: 1, info: nil)
  end

  def true_type_font(*entries)
    offset = 4 + (8 * entries.size)
    tables = {}.compare_by_identity
    records = entries.map do |platform, encoding, data|
      unless tables.key?(data)
        tables[data] = [offset, data]
        offset += data.bytesize
      end
      [platform, encoding, tables.fetch(data).first].pack('nnN')
    end.join
    cmap = [0, entries.size].pack('nn') + records +
           tables.values.map(&:last).join
    [0x00010000, 1, 0, 0, 0].pack('Nn4') +
      ['cmap', 0, 28, cmap.bytesize].pack('a4N3') + cmap
  end

  def cmap_zero(mappings)
    [0, 262, 0].pack('n3') +
      Array.new(256) { |code| mappings.fetch(code, 0) }.pack('C*')
  end

  def cmap_four(segments, sentinel: true)
    rows = segments.map(&:dup)
    rows << [0xFFFF, 0xFFFF, 1] if sentinel
    count = rows.size
    glyphs = []
    offsets = rows.each_with_index.map do |row, i|
      next 0 unless row[3]

      relative = 16 + (8 * count) + (2 * glyphs.size) -
                 (16 + (6 * count) + (2 * i))
      glyphs.concat(row[3])
      relative
    end
    [4, 16 + (8 * count) + (2 * glyphs.size), 0, 2 * count, 0, 0, 0].
      pack('n7') +
      rows.map { |row| row[1] }.pack('n*') + [0].pack('n') +
      rows.map(&:first).pack('n*') +
      rows.map { |row| row[2] & 0xFFFF }.pack('n*') + offsets.pack('n*') +
      glyphs.pack('n*')
  end

  def cmap_six(first, glyphs)
    [6, 10 + (2 * glyphs.size), 0, first, glyphs.size].pack('n5') +
      glyphs.pack('n*')
  end

  def cmap_twelve(groups)
    [12, 0, 16 + (12 * groups.size), 0, groups.size].pack('nnNNN') +
      groups.flatten.pack('N*')
  end
end
