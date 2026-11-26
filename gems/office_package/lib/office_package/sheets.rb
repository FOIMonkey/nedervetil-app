# frozen_string_literal: true

require 'bigdecimal'
require 'date'
require 'office_package'
require 'office_package/inspector'

module OfficePackage
  # What a reader sees of a workbook: visible sheets, rows and columns, each
  # cell as its number format shows it, cells hidden by format or colour left
  # out and counted. Hidden content never reaches page text, search or a
  # visible-cells copy. Disclosures::Sheets words its refusals.
  #
  # Each sheet is { name:, rows:, total_rows:, total_columns:, hidden_cells:,
  # unformatted_cells:, hidden_values: }. unformatted_cells: number formats
  # NumberFormat can't follow, given as stored. hidden_values: what the hidden
  # cells hold (up to MAX_HIDDEN_VALUES), for the score tier.
  module Sheets
    # reason: "conditional_formatting", "too_large_to_copy" or
    # "too_large_to_read".
    class Refused < StandardError
      attr_reader :reason

      def initialize(reason)
        @reason = reason
        super
      end
    end

    # Only when whole sheets are wanted (a visible-cells copy). Writing 500,000
    # cells takes about 15 s and 1.3 GB.
    MAX_CELLS = 200_000
    # Excel's grid ends at column XFD; cells read (not only kept) are capped per
    # workbook.
    LAST_COLUMN = 16_383
    MAX_READ_CELLS = 2_000_000
    MAX_HIDDEN_VALUES = 100_000
    # Largest RGB channel difference at which text and fill can't be told
    # apart.
    SAME_COLOUR = 24
    # The rest of the legacy indexed palette stays unknown.
    INDEXED = { 0 => '000000', 1 => 'FFFFFF', 8 => '000000', 9 => 'FFFFFF',
                64 => '000000', 65 => 'FFFFFF' }.freeze
    # sections: the number format parsed (nil if NumberFormat can't).
    Style = Struct.new(:sections, :font, :fill, keyword_init: true)
    GENERAL = Style.new(sections: [[[:general]]].freeze).freeze
    Book = Struct.new(:shared, :styles, :date1904, :cells, keyword_init: true)
    # How XML attributes spell true.
    TRUE_VALUES = %w[1 true].freeze

    module_function

    # max_rows, max_columns: nil for no limit, but never more than max_cells
    # cells in the workbook. max_read_cells: the most cells read, kept or not.
    def read_xlsx(path, max_rows:, max_columns:, max_cells: MAX_CELLS,
                  max_read_cells: MAX_READ_CELLS)
      zip = OfficePackage.read(File.binread(path))
      workbook = xml(zip, 'xl/workbook.xml')
      relations = relations(zip)
      date1904 = TRUE_VALUES.include?(
        workbook.at_xpath('//*[local-name()="workbookPr"]')&.[]('date1904').
        to_s
      )
      book = Book.new(shared: shared_strings(zip),
                      styles: styles(zip),
                      date1904: date1904,
                      cells: { count: 0, read: 0, max: max_cells,
                               max_read: max_read_cells })
      workbook.xpath('//*[local-name()="sheets"]/' \
                     '*[local-name()="sheet"]').filter_map do |sheet|
        next unless sheet['state'].nil? || sheet['state'] == 'visible'

        relation = relationship_id(sheet)
        part = relations[relation] or next
        read_sheet(sheet['name'].to_s, xml(zip, part), book,
                   max_rows, max_columns)
      end
    end

    def relationship_id(sheet)
      sheet.attribute_nodes.find do |node|
        node.name == 'id' &&
          node.namespace&.href.to_s.end_with?('/relationships')
      end&.value
    end

    def read_sheet(name, document, book, max_rows, max_columns)
      # Conditional rules (including x14 extensions) can hide values by
      # changing their colour or number format. They can't be evaluated here,
      # so raw values are never copied.
      if document.at_xpath('//*[local-name()="conditionalFormatting" or ' \
                           'local-name()="conditionalFormattings"]')
        raise Refused, 'conditional_formatting'
      end

      hidden_columns = hidden_columns(document)
      rows = []
      total = 0
      columns = 0
      tally = Hash.new(0)
      tally[:values] = []
      document.xpath('//*[local-name()="sheetData"]/' \
                     '*[local-name()="row"]').each do |row|
        next if TRUE_VALUES.include?(row['hidden'].to_s)

        total += 1
        if max_rows && rows.size >= max_rows
          columns = [columns, row_width(row, hidden_columns, book.cells)].max
          next
        end
        values, width = row_values(
          row, book, hidden_columns, tally, max_columns
        )
        columns = [columns, width].max
        keep(rows, values, max_rows, max_columns, book.cells)
      end
      rows.pop while rows.any? &&
                     rows.last.all? { |cell| OfficePackage.blank?(cell) }
      { name: name,
        rows: rows,
        total_rows: total,
        total_columns: columns,
        hidden_cells: tally[:hidden],
        unformatted_cells: tally[:unformatted],
        hidden_values: tally[:values] }
    end

    # nil limits: no limit, but never more than cells[:max] cells in the
    # workbook.
    def keep(rows, values, max_rows, max_columns, cells)
      return if max_rows && rows.size >= max_rows

      row = max_columns ? values.first(max_columns) : values
      rows << row
      return unless max_rows.nil?

      cells[:count] += row.size
      return unless cells[:count] > cells[:max]

      raise Refused, 'too_large_to_copy'
    end

    # [the visible values, at most max_columns of them; the row's full visible
    # width].
    def row_values(row, book, hidden_columns, tally, max_columns = nil)
      cells = {}
      next_index = 0
      row.xpath('./*[local-name()="c"]').each do |cell|
        read!(book.cells)
        index = cell['r'] ? column_index(cell['r']) : next_index
        next_index = index + 1
        # Off the grid: Excel can't show it, so it's hidden content.
        if index > LAST_COLUMN || hidden_columns.include?(index)
          hide(tally, stored(cell, book)) if index > LAST_COLUMN
          next
        end

        cells[index] = shown(cell, book, tally)
      end
      return [[], 0] if cells.empty?

      last = cells.keys.max
      visible = (0..last).lazy.reject { |index| hidden_columns.include?(index) }
      visible = visible.first(max_columns) if max_columns
      [visible.map { |index| cells[index].to_s }.to_a,
       visible_width(last, hidden_columns)]
    end

    def row_width(row, hidden_columns, counter)
      index = -1
      last = -1
      row.xpath('./*[local-name()="c"]').each do |cell|
        read!(counter)
        index = cell['r'] ? column_index(cell['r']) : index + 1
        last = index if index <= LAST_COLUMN && !hidden_columns.include?(index)
      end
      last.negative? ? 0 : visible_width(last, hidden_columns)
    end

    def visible_width(last, hidden_columns)
      sorted = hidden_columns.sorted
      last + 1 - (sorted.bsearch_index { |index| index > last } || sorted.size)
    end

    def read!(counter)
      counter[:read] = counter[:read].to_i + 1
      return unless counter[:read] > counter[:max_read]

      raise Refused, 'too_large_to_read'
    end

    def shown(cell, book, tally)
      style = book.styles[cell['s'].to_i] || GENERAL
      value = stored(cell, book)
      return value if value.strip.empty? || cell['t'] == 'e'
      raise NumberFormat::Unknown unless style.sections

      text, colour = if %w[s inlineStr str b d].include?(cell['t'])
                       NumberFormat.text(value, style.sections)
                     else
                       NumberFormat.number(value, style.sections, book.date1904)
                     end
      if text.strip.empty? || same_colour?(colour || style.font, style.fill)
        hide(tally, value)
        return ''
      end
      text
    rescue NumberFormat::Unknown
      tally[:unformatted] += 1
      value
    end

    # The cell's value as stored, before its number format.
    def stored(cell, book)
      raw = cell.at_xpath('./*[local-name()="v"]')&.text
      case cell['t']
      when 's' then book.shared[raw.to_i].to_s
      when 'inlineStr'
        cell.xpath('.//*[local-name()="t"]').map(&:text).join
      when 'b'
        { '1' => 'TRUE', '0' => 'FALSE' }.fetch(raw, raw.to_s)
      else raw.to_s
      end
    end

    def hide(tally, value)
      tally[:hidden] += 1
      values = tally[:values]
      values << value if values.is_a?(Array) && values.size < MAX_HIDDEN_VALUES
    end

    def same_colour?(text, fill)
      return false unless text && fill

      text.scan(/../).zip(fill.scan(/../)).
        map { |a, b| (a.hex - b.hex).abs }.max < SAME_COLOUR
    end

    # "BC12" -> 54 (zero-based column of a cell reference).
    def column_index(reference)
      reference.to_s[/\A[A-Z]+/i].to_s.upcase.each_char.
        reduce(0) { |sum, char| (sum * 26) + (char.ord - 64) } - 1
    end

    HiddenColumns = Struct.new(:set, :sorted) do
      def include?(index)
        set.include?(index)
      end
    end

    # Ranges are merged first, so thousands of overlapping <col> ranges cost no
    # more than one.
    def hidden_columns(document)
      ranges = document.xpath('//*[local-name()="cols"]/' \
                              '*[local-name()="col"]').filter_map do |col|
        next unless TRUE_VALUES.include?(col['hidden'].to_s)

        first = (col['min'].to_i - 1).clamp(0, LAST_COLUMN)
        [first, (col['max'].to_i - 1).clamp(first, LAST_COLUMN)]
      end
      merged = ranges.sort.each_with_object([]) do |(first, last), out|
        if out.any? && first <= out.last[1] + 1
          out.last[1] = [out.last[1], last].max
        else
          out << [first, last]
        end
      end
      sorted = merged.flat_map { |first, last| (first..last).to_a }
      HiddenColumns.new(sorted.to_set, sorted)
    end

    def shared_strings(zip)
      return [] unless zip.include?('xl/sharedStrings.xml')

      xml(zip, 'xl/sharedStrings.xml').xpath('//*[local-name()="si"]').
        map do |item|
          item.xpath(
            './*[local-name()="t"] | ./*[local-name()="r"]/*[local-name()="t"]'
          ).map(&:text).join
        end
    end

    # Per cellXfs entry: number format, and font and fill as RRGGBB where known
    # (no fill: white).
    def styles(zip)
      return [] unless zip.include?('xl/styles.xml')

      styles = xml(zip, 'xl/styles.xml')
      theme = theme_colours(zip)
      codes = styles.xpath('//*[local-name()="numFmts"]/' \
                           '*[local-name()="numFmt"]').
        to_h { |format| [format['numFmtId'].to_i, format['formatCode'].to_s] }
      fonts = styles.xpath('//*[local-name()="fonts"]/' \
                           '*[local-name()="font"]').map do |font|
        colour = font.at_xpath('./*[local-name()="color"]')
        colour ? colour_of(colour, theme) : '000000'
      end
      fills = styles.xpath('//*[local-name()="fills"]/' \
                           '*[local-name()="fill"]').
        map { |fill| fill_colour(fill, theme) }
      parsed = Hash.new do |hash, code|
        hash[code] =
          begin
            NumberFormat.sections(code)
          rescue NumberFormat::Unknown
            nil
          end
      end
      styles.xpath('//*[local-name()="cellXfs"]/' \
                   '*[local-name()="xf"]').map do |xf|
        id = xf['numFmtId'].to_i
        Style.new(sections: parsed[codes[id] ||
                                   NumberFormat::BUILT_IN.fetch(id, 'General')],
                  font: fonts[xf['fontId'].to_i],
                  fill: fills[xf['fillId'].to_i])
      end
    end

    def fill_colour(fill, theme)
      return 'FFFFFF' if fill.element_children.empty?

      pattern = fill.at_xpath('./*[local-name()="patternFill"]') or return nil
      type = pattern['patternType'].to_s
      return 'FFFFFF' if type.empty? || type == 'none'
      return nil unless type == 'solid'

      colour = pattern.at_xpath('./*[local-name()="fgColor"]')
      colour && colour_of(colour, theme)
    end

    def colour_of(node, theme)
      base = if node['rgb'] then node['rgb'].to_s[-6..].to_s.upcase
             elsif node['theme'] then theme[node['theme'].to_i]
             elsif node['indexed'] then INDEXED[node['indexed'].to_i]
             elsif TRUE_VALUES.include?(node['auto'].to_s) then '000000'
             end
      return nil unless base.to_s.match?(/\A\h{6}\z/)

      tint = node['tint'].to_f
      return base if tint.zero?

      base.scan(/../).map do |pair|
        channel = pair.hex
        channel = if tint.negative?
                    channel * (1 + tint)
                  else
                    channel + ((255 - channel) * tint)
                  end
        format('%02X', channel.round.clamp(0, 255))
      end.join
    end

    # Theme colours in the order cells number them: light 1, dark 1, light
    # 2, dark 2, then the accents. The theme part lists each pair dark first.
    def theme_colours(zip)
      defaults = %w[FFFFFF 000000 EEECE1 1F497D]
      return defaults unless zip.include?('xl/theme/theme1.xml')

      scheme = xml(zip, 'xl/theme/theme1.xml').
        at_xpath('//*[local-name()="clrScheme"]') or return defaults
      colours = scheme.element_children.map do |child|
        value = child.at_xpath('./*[local-name()="srgbClr"]')&.[]('val') ||
                child.at_xpath('./*[local-name()="sysClr"]')&.[]('lastClr')
        colour = value.to_s.upcase
        colour unless OfficePackage.blank?(colour)
      end
      return defaults if colours.size < 4

      colours[0], colours[1], colours[2], colours[3] =
        colours[1], colours[0], colours[3], colours[2]
      colours
    end

    def relations(zip)
      xml(zip, 'xl/_rels/workbook.xml.rels').xpath(
        '//*[local-name()="Relationship"]'
      ).to_h do |relation|
        target = relation['Target'].to_s
        path = if target.start_with?('/')
                 target.delete_prefix('/')
               else
                 File.join('xl', target)
               end
        [relation['Id'], path]
      end
    end

    def xml(zip, name)
      Inspector.xml(zip, name)
    end

    # Common number formats; anything else (fractions, other calendars) raises
    # Unknown.
    module NumberFormat
      Unknown = Class.new(StandardError)
      # ECMA-376 18.8.30. 14 and 22 follow the reader's locale, so they are
      # ISO dates here; 5 to 8 are the locale's currency, here without it.
      BUILT_IN = {
        0 => 'General', 1 => '0', 2 => '0.00', 3 => '#,##0', 4 => '#,##0.00',
        5 => '#,##0;-#,##0', 6 => '#,##0;-#,##0', 7 => '#,##0.00;-#,##0.00',
        8 => '#,##0.00;-#,##0.00', 9 => '0%', 10 => '0.00%', 11 => '0.00E+00',
        12 => '# ?/?', 13 => '# ??/??', 14 => 'yyyy-mm-dd', 15 => 'd-mmm-yy',
        16 => 'd-mmm', 17 => 'mmm-yy', 18 => 'h:mm AM/PM',
        19 => 'h:mm:ss AM/PM', 20 => 'h:mm', 21 => 'h:mm:ss',
        22 => 'yyyy-mm-dd hh:mm', 37 => '#,##0 ;(#,##0)',
        38 => '#,##0 ;(#,##0)', 39 => '#,##0.00;(#,##0.00)',
        40 => '#,##0.00;(#,##0.00)', 45 => 'mm:ss', 46 => '[h]:mm:ss',
        47 => 'mm:ss.0', 48 => '##0.0E+0', 49 => '@'
      }.freeze
      COLOURS = {
        'black' => '000000', 'white' => 'FFFFFF', 'red' => 'FF0000',
        'green' => '00FF00', 'blue' => '0000FF', 'yellow' => 'FFFF00',
        'magenta' => 'FF00FF', 'cyan' => '00FFFF'
      }.freeze
      LITERAL = %(\s$-+():!^&'~{}<>=)
      EPOCH = Date.new(1899, 12, 30)

      module_function

      # [shown, colour] from the stored text ("45658.5").
      def number(raw, parts, date1904)
        section, value = section_for(parts, BigDecimal(raw))
        kinds = section.map(&:first)
        text = if kinds.intersect?(%i[date elapsed ampm])
                 date(section, value, date1904)
               else
                 (value.negative? ? '-' : '') + number_text(section, value.abs)
               end
        [text.strip, colour_in(section)]
      rescue ArgumentError, TypeError, FloatDomainError, ZeroDivisionError
        raise Unknown
      end

      # [shown, colour] through the fourth section or one with @, else the text
      # itself.
      def text(value, parts)
        section = if parts.size >= 4
                    parts[3]
                  else
                    parts.find { |part| part.any? { |kind, _| kind == :text } }
                  end
        unless section
          return [value, parts.size == 1 ? colour_in(parts.first) : nil]
        end
        unless section.all? { |kind, _| %i[text literal colour].include?(kind) }
          raise Unknown
        end

        [section.map { |kind, piece| kind == :text ? value : piece.to_s }.join,
         colour_in(section)]
      end

      def sections(code)
        code = 'General' if code.to_s.strip.empty?
        tokens(code.to_s).each_with_object([[]]) do |token, parts|
          token.first == :section ? parts << [] : parts.last << token
        end
      end

      # A negatives section shows its own sign, so the value goes in unsigned.
      def section_for(parts, value)
        numeric = parts.size >= 4 ? parts.first(3) : parts
        conditions = numeric.map do |part|
          part.find { |kind, _| kind == :condition }
        end
        if conditions.any?
          index = conditions.index { |condition|
            condition && meets?(value, condition)
          } || conditions.index(nil) or raise Unknown
          return [numeric[index], value]
        end
        return [numeric[0], value] if numeric.size == 1 || value.positive?
        return [numeric[1], value.abs] if value.negative?

        [numeric[2] || numeric[0], value]
      end

      def meets?(value, (_, operator, limit))
        { '<' => value < limit, '<=' => value <= limit,
          '>' => value > limit, '>=' => value >= limit,
          '=' => value == limit, '<>' => value != limit }.fetch(operator)
      end

      def colour_in(section)
        section.find { |kind, _| kind == :colour }&.last
      end

      def tokens(code)
        out = []
        index = 0
        while index < code.length
          char = code[index]
          rest = code[index..]
          case char
          when ';' then out << [:section]
          when '"'
            close = code.index('"', index + 1) || code.length
            out << [:literal, code[(index + 1)...close]]
            index = close
          when '\\'
            out << [:literal, code[index + 1].to_s]
            index += 1
          when '_'
            out << [:literal, ' ']
            index += 1
          when '*' then index += 1
          when '['
            close = code.index(']', index) or raise Unknown
            out << bracket(code[(index + 1)...close])
            index = close
          when '0', '#', '?' then out << [:digit, char]
          when '.' then out << [:point]
          when ',' then out << [:comma]
          when '%' then out << [:percent]
          when '@' then out << [:text]
          when '/' then out << [:slash]
          else
            if (word = rest[%r{\A(?:General|AM/PM|A/P)}i])
              out << word_token(word)
              index += word.length - 1
            elsif (exponent = rest[/\A[Ee][+-]/])
              out << [:exp, exponent]
              index += 1
            elsif (part = rest[/\A(?:y+|m+|d+|h+|s+)/i])
              out << [:date, part.downcase]
              index += part.length - 1
            elsif LITERAL.include?(char) || !char.ascii_only?
              out << [:literal, char]
            else
              raise Unknown
            end
          end
          index += 1
        end
        out
      end

      def word_token(word)
        word.casecmp?('General') ? [:general] : [:ampm, word]
      end

      def bracket(inner)
        case inner
        when /\A(?:h+|m+|s+)\z/i then [:elapsed, inner.downcase]
        when /\A\$([^-]*)(?:-\h+)?\z/ then [:literal, Regexp.last_match(1)]
        when /\A(<=|>=|<>|<|>|=)\s*(-?\d+(?:\.\d+)?)\z/
          [:condition, Regexp.last_match(1), BigDecimal(Regexp.last_match(2))]
        when /\Acolou?r\s*\d+\z/i then [:colour, nil]
        else [:colour, COLOURS.fetch(inner.downcase) { raise Unknown }]
        end
      end

      def number_text(section, value)
        kinds = section.map(&:first)
        places = kinds.each_index.select { |index| kinds[index] == :digit }
        if places.empty?
          return section.map do |kind, piece|
            { general: general(value),
              text: general(value),
              literal: piece,
              percent: '%' }.fetch(kind, '')
          end.join
        end
        raise Unknown if kinds.intersect?(%i[slash general text])

        value *= 100**kinds.count(:percent)
        scale = 0
        scale += 1 while kinds[places.last + 1 + scale] == :comma
        value /= 1000**scale
        return scientific(section, value) if kinds.include?(:exp)

        point = kinds.index(:point)
        left = point ? section[0...point] : section
        right = point ? section[(point + 1)..] : []
        decimals = right.count { |kind, _| kind == :digit }
        whole, fraction = value.round(decimals, BigDecimal::ROUND_HALF_UP).
          to_s('F').split('.')
        whole = '' if whole == '0'
        text = integer(left, whole, grouped?(left))
        if point
          "#{text}." \
          "#{decimals(right, fraction.to_s.ljust(decimals, '0')[0, decimals])}"
        else
          text
        end
      end

      def general(value)
        value.frac.zero? ? value.to_i.to_s : value.to_s('F')
      end

      # A comma between digit placeholders groups thousands.
      def grouped?(tokens)
        places = tokens.each_index.
          select { |index| tokens[index].first == :digit }
        tokens.each_index.any? do |index|
          tokens[index].first == :comma &&
            places.any? { |place| place < index } &&
            places.any? { |place| place > index }
        end
      end

      # The digits right to left into the placeholders; the leftmost takes
      # any left over. With no digits for it, 0 shows 0, ? a space, # nothing.
      def integer(tokens, digits, group)
        places = tokens.each_index.
          select { |index| tokens[index].first == :digit }
        return literal_text(tokens) + digits if places.empty?

        remaining = digits.chars
        out = []
        count = 0
        placeholders = { '0' => '0', '?' => ' ' }
        tokens.each_index.reverse_each do |index|
          kind, piece = tokens[index]
          case kind
          when :digit
            chunk = remaining.pop(index == places.first ? remaining.size : 1)
            chunk = [placeholders[piece]].compact if chunk.empty?
            chunk.reverse_each do |char|
              if group && char != ' ' && count.positive? && (count % 3).zero?
                out.unshift(',')
              end
              out.unshift(char)
              count += 1 unless char == ' '
            end
          when :literal then out.unshift(piece)
          when :percent then out.unshift('%')
          end
        end
        out.join
      end

      # Trailing zeros under # fall away (under ?, become spaces).
      def decimals(tokens, fraction)
        places = tokens.each_index.
          select { |index| tokens[index].first == :digit }
        chars = fraction.chars
        (places.size - 1).downto(0) do |n|
          placeholder = tokens[places[n]].last
          break unless chars[n] == '0' && placeholder != '0'

          chars[n] = placeholder == '?' ? ' ' : ''
        end
        digits = chars.each
        tokens.map do |kind, piece|
          case kind
          when :digit then digits.next
          when :literal then piece
          when :percent then '%'
          when :point then '.'
          end
        end.join
      end

      def literal_text(tokens)
        tokens.map do |kind, piece|
          { literal: piece, percent: '%' }.fetch(kind, '')
        end.join
      end

      # One digit before the point; engineering notation raises Unknown.
      def scientific(section, value)
        at = section.index { |kind, _| kind == :exp }
        mantissa = section[0...at]
        exponent = section[(at + 1)..]
        unless mantissa.take_while { |kind, _| kind != :point }.
                 count { |kind, _| kind == :digit } == 1
          raise Unknown
        end

        decimals = mantissa.drop_while { |kind, _| kind != :point }.
          count { |kind, _| kind == :digit }
        power = value.zero? ? 0 : value.exponent - 1
        scaled = (value / (BigDecimal(10)**power)).
          round(decimals, BigDecimal::ROUND_HALF_UP)
        if scaled >= 10
          power += 1
          scaled = (value / (BigDecimal(10)**power)).
            round(decimals, BigDecimal::ROUND_HALF_UP)
        end
        sign = power.negative? ? '-' : section[at].last[1].sub('-', '')
        width = exponent.take_while { |kind, _| kind == :digit }.size
        "#{number_text(mantissa, scaled)}#{section[at].last[0]}#{sign}" \
          "#{power.abs.to_s.rjust(width, '0')}" \
          "#{literal_text(exponent.drop_while { |kind, _| kind == :digit })}"
      end

      def date(section, value, date1904)
        if value.negative? ||
           section.any? { |kind, _| %i[digit general text exp].include?(kind) }
          raise Unknown
        end

        days = value.floor
        seconds = ((value - days) * 86_400).round
        if seconds >= 86_400
          days += 1
          seconds = 0
        end
        day = (date1904 ? Date.new(1904, 1, 1) : EPOCH) + days
        twelve = section.any? { |kind, _| kind == :ampm }
        section.each_with_index.map do |(kind, piece), index|
          case kind
          when :date
            date_part(piece, minute?(section, index), day, seconds, twelve)
          when :elapsed
            total = (days * 86_400) + seconds
            { 'h' => total / 3600, 'm' => total / 60, 's' => total }.
              fetch(piece[0]).to_s.rjust(piece.size, '0')
          when :ampm
            half = seconds < 43_200 ? 'AM' : 'PM'
            half = half[0] if piece.size == 3
            piece == piece.downcase ? half.downcase : half
          when :literal then piece
          when :point then '.'
          when :comma then ','
          when :slash then '/'
          when :percent then '%'
          else ''
          end
        end.join
      end

      def date_part(piece, minute, day, seconds, twelve)
        size = piece.size
        two = ->(number) { size > 1 ? format('%02d', number) : number.to_s }
        case piece[0]
        when 'y'
          size > 2 ? format('%04d', day.year) : format('%02d', day.year % 100)
        when 'm'
          if size <= 2 then two.call(minute ? (seconds % 3600) / 60 : day.month)
          elsif size == 3 then Date::ABBR_MONTHNAMES[day.month]
          elsif size == 5 then Date::MONTHNAMES[day.month][0]
          else Date::MONTHNAMES[day.month]
          end
        when 'd'
          if size <= 2 then two.call(day.day)
          elsif size == 3 then Date::ABBR_DAYNAMES[day.wday]
          else Date::DAYNAMES[day.wday]
          end
        when 'h'
          two.call(
            twelve ? ((seconds / 3600) % 12).nonzero? || 12 : seconds / 3600
          )
        when 's' then two.call(seconds % 60)
        end
      end

      # m and mm are minutes after an hour or before seconds, else months.
      def minute?(section, index)
        timed = ->((kind, _)) { %i[date elapsed].include?(kind) }
        before = section[0...index].reverse.find(&timed)
        after = section[(index + 1)..].find(&timed)
        before&.last.to_s.start_with?('h') || after&.last.to_s.start_with?('s')
      end
    end
  end
end
