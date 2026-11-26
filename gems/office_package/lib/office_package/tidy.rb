# frozen_string_literal: true

module OfficePackage
  # Strips removable hidden data (tracked changes, comments, properties,
  # thumbnails, custom XML, XML comments, linked caches, untied pivots,
  # unreachable parts, broken signatures and zip leftovers) from an Office
  # package. Re-surveys the output and raises Error if any remain; returns
  # input bytes untouched when nothing changed.
  class Tidy
    Result = Struct.new(:bytes, :removed, :kept, keyword_init: true) do
      def changed?
        removed.any?
      end
    end

    TYPES = %w[tracked_changes comments author_lists properties thumbnail
               custom_xml xml_comments linked_workbook_caches pivot_tables
               unlisted_parts signatures unlisted_bytes].freeze
    # How a comment starts in an XML part, in each encoding a part can use.
    XML_COMMENT = ['<!--'.b, '<!--'.encode('UTF-16LE').b,
                   '<!--'.encode('UTF-16BE').b].freeze

    DC = 'http://purl.org/dc/elements/1.1/'
    DCTERMS = 'http://purl.org/dc/terms/'
    CORE_KEPT = [[DC, 'title'], [DC, 'language'],
                 [DCTERMS, 'created'], [DCTERMS, 'modified']].freeze

    CHANGES = %w[ins del moveFrom moveTo].freeze
    PROPERTY_CHANGES = %w[rPrChange pPrChange sectPrChange tblPrChange
                          tblPrExChange tblGridChange trPrChange tcPrChange
                          numberingChange].freeze
    CELL_CHANGES = %w[cellIns cellDel cellMerge].freeze
    DELETED_TEXT = %w[delText delInstrText].freeze
    RANGE_MARKS = %w[moveFromRangeStart moveFromRangeEnd moveToRangeStart
                     moveToRangeEnd customXmlInsRangeStart
                     customXmlInsRangeEnd customXmlDelRangeStart
                     customXmlDelRangeEnd customXmlMoveFromRangeStart
                     customXmlMoveFromRangeEnd customXmlMoveToRangeStart
                     customXmlMoveToRangeEnd].freeze
    COMMENT_ANCHORS = %w[commentRangeStart commentRangeEnd
                         commentReference].freeze
    WORD_SETTINGS = %w[docVars attachedTemplate mailMerge].freeze
    SETTINGS_LINKS = %w[attachedTemplate mailMergeSource
                        mailMergeHeaderSource recipientData].freeze
    SHEETS = %w[worksheet chartsheet dialogsheet xlMacrosheet
                xlIntlMacrosheet].freeze
    AUTHOR_TYPES = /(?:\.|-)(?:people|person|commentAuthors|authors)\+xml\z/i
    COMMENT_TYPES = /comments(?:Extended|Ids|Extensible)?\+xml\z/i
    PIVOT_TYPES = /pivot(?:Table|CacheDefinition|CacheRecords)\+xml\z/i
    PIVOT_TIES = %r{\Axl/(?:slicers|slicerCaches|timelines|timelineCaches|
                    model)/}xi
    LINK_PATH = /\A(?:externalLinkPath|xlPathMissing|xlExternalLinkPath|
                  xlStartup|xlAlternateStartup|xlLibrary)\z/xi

    def self.call(bytes)
      new(OfficePackage.read(bytes)).call
    end

    # What a package holds of each type, without changing it.
    def self.survey(bytes)
      new(OfficePackage.read(bytes)).survey
    end

    attr_reader :package

    def initialize(package)
      @package = package
      @removed = Hash.new(0)
      @kept = Hash.new(0)
    end

    def call
      kind = package.kind or raise Refused,
                                   'not a Word, Excel or PowerPoint file'
      orphans = package.unreachable_parts
      orphans.each { |name| package.remove(name) }
      @removed['unlisted_parts'] += orphans.size
      send(kind)
      sweep
      properties
      thumbnail
      custom_xml
      bindings if kind == :document
      xml_comments
      # What only removed parts used (a comment's picture) goes with them.
      package.unreachable_parts.each { |name| package.remove(name) }
      signatures
      unlisted_bytes
      bytes = package.to_bytes
      verify!(bytes, unchanged: bytes.equal?(package.archive.bytes))
      Result.new(bytes: bytes, removed: counts(@removed), kept: counts(@kept))
    end

    def survey
      found = Hash.new(0)
      word_parts.each do |name|
        doc = package.xml(name)
        found['tracked_changes'] += changes(doc)
        found['comments'] += word_nodes(doc, COMMENT_ANCHORS).size
      end
      package.names.each do |name|
        type = package.content_type(name).to_s
        found['comments'] += 1 if type.match?(COMMENT_TYPES)
        found['author_lists'] += 1 if type.match?(AUTHOR_TYPES)
        found['pivot_tables'] += 1 if type.match?(PIVOT_TYPES)
        found['comments'] += vml_notes(name).size if name.match?(/\.vml\z/i)
        found['custom_xml'] += 1 if name.match?(%r{\AcustomXml/}i)
        if type.include?('extended-properties') ||
           type.include?('custom-properties')
          found['properties'] += 1
        end
        found['properties'] += core_extras(name).size if
          type.include?('core-properties')
        found['linked_workbook_caches'] += 1 if
          type.include?('externalLink') && linked_cache?(name)
      end
      found['properties'] += settings_extras.size
      found['xml_comments'] += commented_parts.sum do |name|
        package.xml(name).xpath('//comment()').size
      end
      found['thumbnail'] += package.related('', 'thumbnail').size
      found['signatures'] += package.related('', 'origin').size
      found['unlisted_parts'] += package.unreachable_parts.size
      found['unlisted_bytes'] += package.leftover_bytes
      counts(found)
    end

    private

    def counts(hash)
      hash.select { |_type, count| count.positive? }.
        sort_by { |type, _count| TYPES.index(type) || TYPES.size }.to_h
    end

    def document
      word_parts.each do |part|
        doc = package.xml(part)
        accepted = accept_changes(doc)
        anchors = remove_anchors(doc)
        package.changed!(part) if accepted.positive? || anchors.positive?
        @removed['tracked_changes'] += accepted
      end
      word_comments
      word_settings
    end

    # Every Word XML part: styles and numbering can hold tracked formatting
    # changes too.
    def word_parts
      package.names.select { |name| word?(name) }
    end

    def word?(name)
      package.content_type(name).to_s.include?('wordprocessingml') &&
        package.xml_part?(name)
    end

    def word_ns(doc)
      href = doc.root&.namespace&.href
      href if WORD_NS.include?(href)
    end

    def word_nodes(doc, names)
      ns = word_ns(doc) or return []
      doc.xpath(names.map { |name| "//w:#{name}" }.join(' | '), 'w' => ns)
    end

    def changes(doc)
      word_nodes(doc, CHANGES + PROPERTY_CHANGES + CELL_CHANGES +
                      DELETED_TEXT).size
    end

    # A change element inside a properties element (w:rPr, w:trPr, w:numPr,
    # m:ctrlPr) marks what holds it; elsewhere it wraps content.
    def accept_changes(doc)
      count = 0
      markers, wrappers = word_nodes(doc, CHANGES).partition do |node|
        node.parent&.name.to_s.end_with?('Pr')
      end
      count += accept_markers(markers)
      count += unwrap(wrappers)
      count += accept_cell_changes(doc)
      (word_nodes(doc, PROPERTY_CHANGES) +
       word_nodes(doc, DELETED_TEXT)).each do |node|
        count += 1
        node.remove
      end
      word_nodes(doc, RANGE_MARKS).each(&:remove)
      count
    end

    def accept_markers(markers)
      count = 0
      markers.each do |marker|
        count += 1
        holder = marker.parent
        if %w[del moveFrom].include?(marker.name) && holder.name == 'rPr' &&
           holder.parent&.name == 'pPr'
          merge_paragraph(holder.parent.parent, marker)
        elsif marker.name == 'del' && holder.name == 'trPr'
          holder.parent.remove
        else
          marker.remove
        end
      end
      count
    end

    def unwrap(wrappers)
      count = 0
      wrappers.each do |node|
        count += 1
        unless %w[del moveFrom].include?(node.name)
          node.children.each { |child| node.add_previous_sibling(child) }
        end
        node.remove
      end
      count
    end

    def accept_cell_changes(doc)
      count = 0
      word_nodes(doc, CELL_CHANGES).each do |node|
        count += 1
        if node.name == 'cellDel'
          node.ancestors.find { |ancestor| ancestor.name == 'tc' }&.remove
        end
        node.remove
      end
      count
    end

    # The paragraph's content moves to the start of the next paragraph,
    # whose mark (and so whose properties) survives.
    def merge_paragraph(paragraph, marker)
      marker.remove
      following = paragraph.next_element
      return unless following&.name == 'p' &&
                    following.namespace&.href == paragraph.namespace&.href

      content = paragraph.children.reject do |node|
        node.element? && node.name == 'pPr'
      end
      properties = following.element_children.first
      if properties&.name == 'pPr'
        last = properties
        content.each do |node|
          last.add_next_sibling(node)
          last = node
        end
      elsif (first = following.children.first)
        content.each { |node| first.add_previous_sibling(node) }
      else
        content.each { |node| following.add_child(node) }
      end
      paragraph.remove
    end

    def remove_anchors(doc)
      nodes = word_nodes(doc, COMMENT_ANCHORS)
      nodes.each do |node|
        run = node.parent
        if node.name == 'commentReference' && run&.name == 'r' &&
           run.element_children.all? do |child|
             child.equal?(node) || child.name == 'rPr'
           end
          run.remove
        else
          node.remove
        end
      end
      nodes.size
    end

    def word_comments
      main = package.main_part
      parts = package.related(main, 'comments', 'commentsExtended',
                              'commentsIds', 'commentsExtensible')
      @removed['comments'] += parts.select { |rel| rel.kind == 'comments' }.
                              sum { |rel| comment_count(rel.target, 'comment') }
      parts.each { |rel| package.remove(rel.target) }
      authors = package.related(main, 'people')
      authors.each { |rel| package.remove(rel.target) }
      @removed['author_lists'] += authors.size
    end

    def word_settings
      settings = package.related(package.main_part, 'settings').first or return
      doc = package.xml(settings.target)
      found = word_nodes(doc, WORD_SETTINGS)
      tracking = word_nodes(doc, %w[trackRevisions])
      links = package.relationships(settings.target).select do |rel|
        SETTINGS_LINKS.include?(rel.kind)
      end
      return if found.empty? && tracking.empty? && links.empty?

      (found + tracking).each(&:remove)
      links.each { |rel| package.drop_relationship(rel) }
      package.changed!(settings.target)
      @settings_removed = found.any? || links.any?
    end

    def settings_extras
      return [] unless package.kind == :document

      settings = package.related(package.main_part, 'settings').first
      return [] unless settings

      word_nodes(package.xml(settings.target), WORD_SETTINGS).to_a +
        package.relationships(settings.target).select do |rel|
          SETTINGS_LINKS.include?(rel.kind)
        end
    end

    # Content controls bound to custom XML or the properties would be
    # refilled from what was removed.
    def bindings
      return unless @removed['custom_xml'].positive? ||
                    @removed['properties'].positive?

      word_parts.each do |part|
        doc = package.xml(part)
        nodes = doc.xpath('//*[local-name()="sdtPr"]/' \
                          '*[local-name()="dataBinding"]')
        next if nodes.empty?

        nodes.each(&:remove)
        package.changed!(part)
      end
    end

    def spreadsheet
      workbook = package.main_part
      sheets = package.related(workbook, *SHEETS).map(&:target)
      sheets.each { |sheet| sheet_comments(sheet) }
      persons = package.related(workbook, 'person')
      persons.each { |rel| package.remove(rel.target) }
      @removed['author_lists'] += persons.size
      pivots(workbook, sheets)
      linked_workbooks(workbook)
    end

    def sheet_comments(sheet)
      legacy = package.related(sheet, 'comments')
      threaded = package.related(sheet, 'threadedComment')
      count = legacy.sum { |rel| comment_count(rel.target, 'comment') }
      if count.zero?
        count = threaded.sum do |rel|
          comment_count(rel.target, 'threadedComment')
        end
      end
      (legacy + threaded).each { |rel| package.remove(rel.target) }
      notes = remove_notes(sheet, comments: (legacy + threaded).any?)
      @removed['comments'] += count.positive? ? count : notes
    end

    # Comment shapes in the sheet's VML drawing. A drawing of nothing else
    # goes, and the sheet's legacyDrawing with it; one that also holds form
    # controls keeps them.
    def remove_notes(sheet, comments:)
      package.related(sheet, 'vmlDrawing').sum do |rel|
        shapes = vml_shapes(rel.target)
        if shapes.nil?
          next 0 unless comments

          package.remove(rel.target)
          next 1
        end
        notes = shapes.select { |shape| note?(shape) }
        next 0 if notes.empty?

        if notes.size == shapes.size
          package.remove(rel.target)
        else
          notes.each(&:remove)
          package.changed!(rel.target)
        end
        notes.size
      end
    end

    def vml_shapes(name)
      doc = package.xml(name)
      # Excel/LibreOffice VML drawings sometimes omit xmlns:v / xmlns:x, so
      # libxml2 parses them with warnings and local-name()="v:shape". Match
      # both declared and prefixed names, and treat a VML with parse errors
      # and no matched shapes as unreadable so remove_notes drops it.
      shapes = doc.xpath(
        '//*[local-name()="shape" or local-name()="v:shape"]'
      ).to_a
      return nil if shapes.empty? && doc.errors.any?

      shapes
    rescue Refused
      nil
    end

    def vml_notes(name)
      Array(vml_shapes(name)).select { |shape| note?(shape) }
    end

    def note?(shape)
      shape.xpath(
        './*[local-name()="ClientData" or local-name()="x:ClientData"]'
      ).any? { |data| data['ObjectType'].to_s.casecmp?('Note') }
    end

    def pivots(workbook, sheets)
      tables = sheets.flat_map { |sheet| package.related(sheet, 'pivotTable') }
      caches = package.related(workbook, 'pivotCacheDefinition')
      return if tables.empty? && caches.empty?

      count = [tables.size, caches.size].max
      if pivots_tied?
        @kept['pivot_tables'] += count
        return
      end

      records = caches.flat_map do |rel|
        package.related(rel.target, 'pivotCacheRecords')
      end
      (tables + records + caches).each { |rel| package.remove(rel.target) }
      sheets.each do |sheet|
        doc = package.xml(sheet)
        selections = doc.xpath('//*[local-name()="pivotSelection"]')
        next if selections.empty?

        selections.each(&:remove)
        package.changed!(sheet)
      end
      @removed['pivot_tables'] += count
    end

    def pivots_tied?
      package.names.any? do |name|
        name.match?(PIVOT_TIES) ||
          (package.content_type(name).to_s.include?('drawingml.chart') &&
           package.read(name).include?('pivotSource'))
      end
    end

    def linked_workbooks(workbook)
      package.related(workbook, 'externalLink').each do |rel|
        doc = package.xml(rel.target)
        cached = doc.xpath('//*[local-name()="sheetDataSet"]')
        changed = cached.any? { |node| node.element_children.any? }
        if cached.any?
          cached.each(&:remove)
          package.changed!(rel.target)
        end
        package.relationships(rel.target).each do |link|
          next unless link.external && link.kind.match?(LINK_PATH)

          base = file_name(link.target)
          next if base.empty? || base == link.target

          link.node['Target'] = base
          package.changed!(package.rels_name(rel.target))
          changed = true
        end
        @removed['linked_workbook_caches'] += 1 if changed
      end
    end

    def linked_cache?(name)
      package.xml(name).xpath('//*[local-name()="sheetDataSet"]').
        any? { |node| node.element_children.any? } ||
        package.relationships(name).any? do |link|
          link.external && link.kind.match?(LINK_PATH) &&
            file_name(link.target) != link.target
        end
    end

    def file_name(target)
      target.to_s.split(%r{[/\\]}).last.to_s
    end

    def presentation
      deck = package.main_part
      package.related(deck, 'slide').each do |slide|
        package.related(slide.target, 'comments').each do |rel|
          @removed['comments'] += comment_count(rel.target, 'cm')
          package.remove(rel.target)
        end
      end
      authors = package.related(deck, 'commentAuthors', 'authors')
      authors.each { |rel| package.remove(rel.target) }
      @removed['author_lists'] += authors.size
    end

    # Comment, author and pivot parts the steps above didn't reach through
    # the usual relationships, found by content type as the survey finds
    # them.
    def sweep
      package.names.each do |name|
        type = package.content_type(name).to_s
        if type.match?(COMMENT_TYPES)
          @removed['comments'] += 1 if @removed['comments'].zero?
        elsif type.match?(AUTHOR_TYPES)
          @removed['author_lists'] += 1
        elsif type.match?(PIVOT_TYPES) && @kept['pivot_tables'].zero?
          @removed['pivot_tables'] += 1 if @removed['pivot_tables'].zero?
        else
          next
        end
        package.remove(name)
      end
    end

    def comment_count(name, element)
      [package.xml(name).xpath("//*[local-name()=\"#{element}\"]").size, 1].max
    rescue Refused
      1
    end

    def properties
      removed = @settings_removed || false
      package.related('', 'core-properties').each do |rel|
        extras = core_extras(rel.target)
        next if extras.empty?

        removed ||= extras.any? { |node| !node.text.strip.empty? }
        extras.each(&:remove)
        package.changed!(rel.target)
      end
      package.related('', 'extended-properties', 'custom-properties').
        each do |rel|
          package.remove(rel.target)
          removed = true
        end
      @removed['properties'] += 1 if removed
    end

    def core_extras(name)
      package.xml(name).root&.element_children.to_a.reject do |node|
        CORE_KEPT.include?([node.namespace&.href, node.name])
      end
    end

    def thumbnail
      found = package.related('', 'thumbnail')
      found.each { |rel| package.remove(rel.target) }
      @removed['thumbnail'] += found.size
    end

    def custom_xml
      parts = package.names.select { |name| name.match?(%r{\AcustomXml/}i) }
      return if parts.empty?

      items = parts.count do |name|
        name.match?(%r{\AcustomXml/item\d*\.xml\z}i)
      end
      parts.each { |name| package.remove(name) }
      @removed['custom_xml'] += [items, 1].max
    end

    def signatures
      return unless package.changed? || @removed.any?

      origins = package.related('', 'origin')
      return if origins.empty?

      origins.each do |origin|
        package.related(origin.target, 'signature').
          each { |rel| package.remove(rel.target) }
        package.remove(origin.target)
      end
      @removed['signatures'] += origins.size
    end

    # XML comments: no reader shows them, and any program can leave notes in
    # them. Only parts that may hold one are parsed.
    def xml_comments
      commented_parts.each do |name|
        nodes = package.xml(name).xpath('//comment()')
        next if nodes.empty?

        @removed['xml_comments'] += nodes.size
        nodes.each(&:remove)
        package.changed!(name)
      end
    end

    def commented_parts
      package.names.select do |name|
        package.xml_part?(name) &&
          XML_COMMENT.any? { |mark| package.read(name).b.include?(mark) }
      end
    end

    def unlisted_bytes
      @removed['unlisted_bytes'] += package.leftover_bytes
    end

    # A signature stays on a file that didn't change, and pivots stay when
    # something depends on them.
    def verify!(bytes, unchanged:)
      left = self.class.survey(bytes).reject do |type, _count|
        (type == 'pivot_tables' && @kept['pivot_tables'].positive?) ||
          (type == 'signatures' && unchanged)
      end
      return if left.empty?

      raise Error, "#{left.keys.join(', ').tr('_', ' ')} could not be removed"
    end
  end
end
