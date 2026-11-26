# frozen_string_literal: true

module OfficePackage
  ##
  # What an Office file holds that its pages don't show, each item with the
  # text it carries, so the score tier can weigh it. The types Tidy removes
  # aren't looked for: a site can have Tidy remove them as a file is
  # published (Disclosures::Tidy).
  #
  # An item is readable when all of its text could be read: a data model, a
  # file embedded in a format this can't open, or more text than MAX_TEXTS,
  # isn't.
  #
  #   OfficePackage::Hidden.call(bytes)
  #   # => [#<Item type="hidden_sheet", name="Staff", texts=[...], ...>]
  class Hidden
    Item = Data.define(:type, :count, :name, :texts, :readable)

    MAX_TEXTS = 100_000
    SHEETS = %w[worksheet xlMacrosheet xlIntlMacrosheet].freeze
    STORIES = %w[header footer footnotes endnotes].freeze

    def self.call(bytes)
      new(OfficePackage.read(bytes)).call
    end

    attr_reader :package

    def initialize(package)
      @package = package
      @items = []
    end

    def call
      case package.kind
      when :spreadsheet then spreadsheet
      when :document then document
      when :presentation then presentation
      end
      embedded
      macros
      title
      @items
    end

    # Text of the parts a reader of each kind of file sees, for a file
    # embedded in another.
    def content_texts
      case package.kind
      when :spreadsheet
        workbook = package.main_part
        shared = shared_strings(workbook)
        sheet_parts(workbook).flat_map do |part|
          cell_texts(package.xml(part).xpath('//*[local-name()="c"]'), shared)
        end
      when :document
        word_parts.flat_map { |part| node_texts(package.xml(part), 't') }
      when :presentation
        package.names.select { |name| name.match?(%r{\Appt/slides/}i) }.
          select { |name| package.xml_part?(name) }.
          flat_map { |part| node_texts(package.xml(part), 't') }
      else []
      end
    end

    private

    def add(type, texts: [], count: nil, name: nil, readable: true)
      texts = texts.map { |text| text.to_s.strip }.reject(&:empty?)
      readable &&= texts.size <= MAX_TEXTS
      @items << Item.new(type: type, count: count, name: name,
                         texts: texts.first(MAX_TEXTS), readable: readable)
    end

    def node_texts(doc, local_name)
      doc.xpath("//*[local-name()=\"#{local_name}\"]").map(&:text)
    end

    def spreadsheet
      workbook = package.main_part
      shared = shared_strings(workbook)
      targets = package.relationships(workbook).to_h do |rel|
        [rel.id, rel.target]
      end
      package.xml(workbook).
        xpath('//*[local-name()="sheets"]/*[local-name()="sheet"]').
        each do |sheet|
          part = targets[relationship_id(sheet)]
          next unless part && package.include?(part)

          sheet_items(sheet, package.xml(part), shared)
        end
      pivot_caches(workbook)
      if package.names.any? { |name| name.match?(%r{\Axl/model/}i) }
        add('data_model', readable: false)
      end
      named_ranges(workbook)
      links = package.related(workbook, 'externalLink').size
      add('external_links', count: links) if links.positive?
    end

    def sheet_items(sheet, doc, shared)
      name = sheet['name'].to_s
      case sheet['state'].to_s
      when 'hidden', 'veryHidden'
        type = if sheet['state'] == 'veryHidden'
                 'very_hidden_sheet'
               else
                 'hidden_sheet'
               end
        add(type, name: name,
                  texts: cell_texts(doc.xpath('//*[local-name()="c"]'), shared))
      else
        rows = doc.xpath('//*[local-name()="sheetData"]/*[local-name()="row"]')
        hidden = rows.select { |row| on?(row['hidden']) }
        if hidden.any?
          cells = hidden.flat_map do |row|
            row.xpath('./*[local-name()="c"]').to_a
          end
          add('hidden_rows', name: name, count: hidden.size,
                             texts: cell_texts(cells, shared))
        end
        ranges = hidden_columns(doc)
        return if ranges.empty?

        cells = (rows.to_a - hidden).flat_map do |row|
          columns_of(row).select do |index, _cell|
            ranges.any? { |first, last| index.between?(first, last) }
          end.map(&:last)
        end
        add('hidden_columns', name: name, count: ranges.size,
                              texts: cell_texts(cells, shared))
      end
    end

    def sheet_parts(workbook)
      package.related(workbook, *SHEETS).map(&:target)
    end

    def relationship_id(node)
      node.attribute_nodes.find do |attribute|
        attribute.name == 'id' &&
          RELATIONSHIPS_NS.include?(attribute.namespace&.href)
      end&.value
    end

    def shared_strings(workbook)
      rel = package.related(workbook, 'sharedStrings').first
      return [] unless rel

      package.xml(rel.target).xpath('//*[local-name()="si"]').map do |item|
        item.xpath('./*[local-name()="t"] | ' \
                   './*[local-name()="r"]/*[local-name()="t"]').
          map(&:text).join
      end
    end

    # Text cells only: shared, inline and formula results stored as text.
    def cell_texts(cells, shared)
      cells.filter_map do |cell|
        case cell['t']
        when 's'
          shared[cell.at_xpath('./*[local-name()="v"]')&.text.to_i]
        when 'inlineStr'
          cell.xpath('.//*[local-name()="t"]').map(&:text).join
        when 'str'
          cell.at_xpath('./*[local-name()="v"]')&.text
        end
      end
    end

    # [[zero-based column, cell], ...], following cells without a reference
    # on from the one before.
    def columns_of(row)
      index = -1
      row.xpath('./*[local-name()="c"]').map do |cell|
        index = cell['r'] ? column_index(cell['r']) : index + 1
        [index, cell]
      end
    end

    def column_index(reference)
      reference.to_s[/\A[A-Z]+/i].to_s.upcase.each_char.
        reduce(0) { |sum, char| (sum * 26) + (char.ord - 64) } - 1
    end

    def hidden_columns(doc)
      doc.xpath('//*[local-name()="cols"]/*[local-name()="col"]').
        filter_map do |col|
          next unless on?(col['hidden'])

          first = col['min'].to_i - 1
          [first, [col['max'].to_i - 1, first].max]
        end
    end

    def on?(value)
      %w[1 true].include?(value.to_s)
    end

    # Pivot caches still here are ones Tidy kept (something depends on them).
    def pivot_caches(workbook)
      caches = package.related(workbook, 'pivotCacheDefinition')
      return if caches.empty?

      texts = caches.flat_map do |rel|
        values = shared_items(package.xml(rel.target))
        package.related(rel.target, 'pivotCacheRecords').each do |records|
          values += shared_items(package.xml(records.target))
        end
        values
      end
      add('pivot_caches', count: caches.size, texts: texts)
    end

    def shared_items(doc)
      doc.xpath('//*[local-name()="s"]').map { |node| node['v'] }
    end

    def named_ranges(workbook)
      count = package.xml(workbook).xpath('//*[local-name()="definedName"]').
              count { |name| !name['name'].to_s.start_with?('_xlnm.') }
      add('named_ranges', count: count) if count.positive?
    end

    def document
      main = package.main_part
      styles = hidden_styles(main)
      stories = [main] + package.related(main, *STORIES).map(&:target)
      texts = stories.uniq.select { |part| package.xml_part?(part) }.
              flat_map { |part| vanished(package.xml(part), styles) }
      add('hidden_text', count: texts.size, texts: texts) if texts.any?
      package.related(main, 'glossaryDocument').each do |rel|
        glossary = package.xml(rel.target)
        found = node_texts(glossary, 't')
        next if found.join.strip.empty?

        parts = glossary.xpath('//*[local-name()="docPart"]').size
        add('building_blocks', count: [parts, 1].max, texts: found)
      end
    end

    def word_parts
      package.names.select do |name|
        package.content_type(name).to_s.include?('wordprocessingml') &&
          package.xml_part?(name)
      end
    end

    def hidden_styles(main)
      rel = package.related(main, 'styles').first
      return Set.new unless rel

      package.xml(rel.target).xpath('//*[local-name()="style"]').
        each_with_object(Set.new) do |style, hidden|
          vanish = style.at_xpath('./*[local-name()="rPr"]/' \
                                  '*[local-name()="vanish"]')
          hidden << attribute(style, 'styleId') if vanish && toggle?(vanish)
        end
    end

    # w:vanish on the run, or through its character or paragraph style: the
    # text of each such run.
    def vanished(doc, styles)
      doc.xpath('//*[local-name()="r"]').filter_map do |run|
        text = run.xpath('./*[local-name()="t"]').map(&:text).join
        next if text.strip.empty?

        vanish = run.at_xpath('./*[local-name()="rPr"]/' \
                              '*[local-name()="vanish"]')
        hidden = if vanish
                   toggle?(vanish)
                 else
                   style = run.at_xpath('./*[local-name()="rPr"]/' \
                                        '*[local-name()="rStyle"]')
                   paragraph = run.at_xpath(
                     'ancestor::*[local-name()="p"][1]/*[local-name()="pPr"]/' \
                     '*[local-name()="pStyle"]'
                   )
                   styles.include?(style && attribute(style, 'val')) ||
                     styles.include?(paragraph && attribute(paragraph, 'val'))
                 end
        text if hidden
      end
    end

    def toggle?(node)
      value = attribute(node, 'val')
      value.nil? || !%w[0 false off].include?(value)
    end

    def attribute(node, name)
      node.attribute_nodes.find { |found| found.name == name }&.value
    end

    def presentation
      deck = package.main_part
      size = package.xml(deck).at_xpath('//*[local-name()="sldSz"]')
      hidden = []
      off = []
      notes = []
      hidden_values = %w[0 false]
      package.related(deck, 'slide').each do |rel|
        slide = package.xml(rel.target)
        if hidden_values.include?(slide.root&.[]('show').to_s)
          hidden << node_texts(slide, 't')
        end
        placed = off_slide(slide, size)
        off << placed if placed.any?
        package.related(rel.target, 'notesSlide').each do |note|
          found = package.xml(note.target).
                  xpath('//*[local-name()="r"]/*[local-name()="t"]').map(&:text)
          notes << found unless found.join.strip.empty?
        end
      end
      add('hidden_slides', count: hidden.size, texts: hidden.flatten) if
        hidden.any?
      add('off_slide_text', count: off.size, texts: off.flatten) if off.any?
      add('speaker_notes', count: notes.size, texts: notes.flatten) if
        notes.any?
    end

    # The text of shapes whose centre is off the slide.
    def off_slide(slide, size)
      return [] unless size

      width = size['cx'].to_i
      height = size['cy'].to_i
      slide.xpath('//*[local-name()="spTree"]/*').flat_map do |shape|
        texts = shape.xpath('.//*[local-name()="t"]').map(&:text)
        next [] if texts.join.strip.empty?

        frame = shape.at_xpath(
          './*[local-name()="spPr" or local-name()="grpSpPr"]/' \
          '*[local-name()="xfrm"] | ./*[local-name()="xfrm"]'
        )
        offset = frame&.at_xpath('./*[local-name()="off"]')
        extent = frame&.at_xpath('./*[local-name()="ext"]')
        next [] unless offset && extent

        x = offset['x'].to_i + (extent['cx'].to_i / 2)
        y = offset['y'].to_i + (extent['cy'].to_i / 2)
        x.between?(0, width) && y.between?(0, height) ? [] : texts
      end
    end

    # A chart's own workbook is listed as the chart's data; other embedded
    # files as embedded files. An Office file inside is read for the text a
    # reader of it would see; anything else can't be read here.
    def embedded
      parts = package.names.select { |name| name.match?(%r{/embeddings/}i) }
      return if parts.empty?

      charts = package.names.select do |name|
        package.content_type(name).to_s.include?('drawingml.chart')
      end
      charts = charts.flat_map do |chart|
        package.related(chart, 'package').map(&:target)
      end
      chart_data = parts.select { |name| charts.include?(name) }
      others = parts - chart_data
      [['chart_data', chart_data],
       ['embedded_files', others]].each do |type, names|
        next if names.empty?

        texts = []
        readable = true
        names.each do |name|
          found = embedded_texts(name)
          if found
            texts.concat(found)
          else
            readable = false
          end
        end
        add(type, count: names.size, texts: texts, readable: readable)
      end
    end

    def embedded_texts(name)
      data = package.read(name)
      return unless OfficePackage.package?(data)

      inner = OfficePackage.read(data)
      return if inner.names.any? { |part| part.match?(%r{/embeddings/}i) }

      Hidden.new(inner).content_texts
    rescue Error
      nil
    end

    def macros
      found = package.names.any? do |name|
        File.basename(name).casecmp?('vbaProject.bin')
      end
      add('macros') if found
    end

    def title
      rel = package.related('', 'core-properties').first or return
      text = package.xml(rel.target).
             at_xpath('//*[local-name()="title"]')&.text.to_s.strip
      add('title', texts: [text]) unless text.empty?
    end
  end
end
