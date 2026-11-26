require 'securerandom'

# Preserves the structure of data tables while HTML email is converted to text.
# elinks draws borders around selected tables, and those lines are displayed in
# a preformatted, horizontally scrollable block.
module EmailTables
  BOX_CHARS = '─│┌┐└┘├┤┬┴┼'.freeze
  BOX_LINE = /\A[ \t]*[#{BOX_CHARS}]/
  BLOCK = /(?:^[ \t]*[#{BOX_CHARS}][^\n]*(?:\n|\z)){2,}/
  NUMERIC = /\A[<>~≤≥£$€]?\s*-?[\d,.]+\s*%?\z/

  MAX_CELL_LENGTH = 250
  MAX_SPAN = 50
  MAX_TABLES = 100
  MAX_CELLS = 2_000
  MAX_ROWS = 200
  MAX_GRID_CELLS = 10_000

  Grid = Struct.new(:rows)

  def self.html_to_text(html)
    doc = Nokogiri::HTML5(html)
    tables = data_tables(doc)
    return yield(html) if tables.empty?

    tables.each { |table| table['border'] = '1' }
    yield(doc.to_html)
  end

  # Keep the spacing elinks uses to align box borders.
  def self.squeeze_spaces(text)
    text.gsub(/^.*$/) do |line|
      line.match?(BOX_LINE) ? line : line.squeeze(' ')
    end
  end

  # The caller escapes body text before it reaches this method. Only the
  # generated placeholder paragraphs are replaced with markup.
  def self.format(text)
    token = loop do
      candidate = "EMAILTABLE#{SecureRandom.hex(16)}"
      break candidate unless text.include?(candidate)
    end
    blocks = []

    with_placeholders = text.gsub(BLOCK) do |block|
      blocks << block
      "\n\n#{token}#{blocks.size - 1}\n\n"
    end

    html = yield(with_placeholders)
    html.gsub(%r{<p>\s*#{Regexp.escape(token)}(\d+)\s*</p>}) do |placeholder|
      block = blocks[Regexp.last_match(1).to_i]
      block ? render_box(block) : placeholder
    end
  end

  def self.data_tables(doc)
    tables = doc.css('table')
    return [] if tables.size > MAX_TABLES

    remaining_cells = MAX_CELLS
    selected = []
    tables.each do |table|
      next if table.at_css('table')

      count = table.css('td, th').size
      break if count > remaining_cells

      remaining_cells -= count
      grid = grid_for(table)
      selected << table if grid && data_grid?(grid)
    end
    selected
  end

  def self.grid_for(table)
    trs = table.css('tr')
    return if trs.size > MAX_ROWS

    cells = cells_for(trs) or return

    rows = Array.new(trs.size) { |row| cells[row] }
    width = rows.map(&:size).max || 0
    rows = rows.map { |row| Array.new(width) { |col| row[col] || '' } }

    # Ignore empty layout spacers when deciding whether a table carries data.
    drop_empty!(rows, width)

    Grid.new(rows)
  end

  def self.cells_for(trs)
    cells = Hash.new { |hash, key| hash[key] = [] }
    expanded_cells = 0
    too_large = false

    trs.each_with_index do |tr, row|
      col = 0
      tr.xpath('./td|./th').each do |td|
        col += 1 while cells[row][col]
        rowspan = td['rowspan'].to_i.clamp(1, [MAX_SPAN, trs.size - row].min)
        colspan = td['colspan'].to_i.clamp(1, MAX_SPAN)
        expanded_cells += rowspan * colspan
        if expanded_cells > MAX_GRID_CELLS
          too_large = true
          break
        end

        rowspan.times do |dr|
          colspan.times { |dc| cells[row + dr][col + dc] = '' }
        end

        cells[row][col] = cell_text(td)
        col += colspan
      end
      break if too_large
    end
    return if too_large

    cells
  end

  def self.drop_empty!(rows, width)
    rows.reject! { |row| row.all?(&:empty?) }
    empty_cols = (0...width).select do |col|
      rows.all? { |row| row[col].empty? }
    end
    rows.each do |row|
      row.reject!.with_index { |_, col| empty_cols.include?(col) }
    end
  end

  # Two-column tables are common in signatures and quoted email headers.
  def self.data_grid?(grid)
    cells = grid.rows.flatten

    grid.rows.size >= 2 &&
      grid.rows.first.size >= 2 &&
      cells.all? { |cell| cell.length <= MAX_CELL_LENGTH } &&
      (grid.rows.first.size >= 3 || cells.any? { |cell| cell.match?(NUMERIC) })
  end

  def self.cell_text(td)
    td = td.dup
    td.css('br').each { |br| br.replace("\n") }
    td.css('p, div, li').each { |block| block.add_next_sibling("\n") }
    td.text.gsub(/[[:space:]]+/, ' ').strip
  end

  def self.render_box(block)
    lines = block.lines.map(&:rstrip)
    indent = lines.map { |line| line[/\A */].size }.min
    pre = lines.map { |line| line[indent..] }.join("\n")

    '<div class="correspondence_table correspondence_table--box">' \
      '<div class="correspondence_table__scroll">' \
      "<pre>#{pre}</pre></div></div>"
  end
end
