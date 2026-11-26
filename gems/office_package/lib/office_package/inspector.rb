# frozen_string_literal: true

require 'office_package'
require 'office_package/package'
require 'office_package/guard'

module OfficePackage
  # What a person reviewing an Office Open XML file may not see in it, as
  # findings: { type:, and count:, name: or value: as the type has them }.
  # AttachmentManagement::OfficeInspector words them. Names and parts through
  # Package, which refuses a zip that is ambiguous, encrypted or whose parts
  # don't match what it says.
  module Inspector
    module_function

    def findings(path)
      zip = OfficePackage.read(File.binread(path))
      names = zip.names
      findings = []
      findings += spreadsheet(zip, names) if names.include?('xl/workbook.xml')
      findings += document(zip, names) if names.include?('word/document.xml')
      if names.any? { |name| name.start_with?('ppt/') }
        findings += presentation(names)
      end
      embedded = names.count { |name| name.match?(%r{\A\w+/embeddings/}) }
      if embedded.positive?
        findings << { type: 'embedded_files', count: embedded }
      end
      findings + properties(zip, names)
    end

    def spreadsheet(zip, names)
      workbook = xml(zip, 'xl/workbook.xml')
      findings = hidden_sheets(workbook)
      labels = sheet_names(zip, names, workbook)
      parts = labels.keys + names.grep(%r{\Axl/worksheets/sheet\d+\.xml\z}).sort
      findings.concat(hidden_rows_and_columns(zip, parts, labels))
      comments = names.grep(%r{\Axl/comments\d*\.xml\z}).sum do |name|
        xml(zip, name).xpath('//*[local-name()="comment"]').size
      end
      if comments.positive?
        findings << { type: 'cell_comments', count: comments }
      end
      findings
    end

    def hidden_sheets(workbook)
      workbook.xpath('//*[local-name()="sheet"][@state]').
        filter_map do |sheet|
          next if sheet['state'] == 'visible'

          very = sheet['state'] == 'veryHidden'
          { type: very ? 'very_hidden_sheet' : 'hidden_sheet',
            name: sheet['name'] }
        end
    end

    def hidden_rows_and_columns(zip, parts, labels)
      findings = []
      parts.uniq.each do |name|
        sheet = xml(zip, name)
        rows = sheet.xpath('//*[local-name()="row"]' \
                           '[@hidden="1" or @hidden="true"]').size
        cols = sheet.xpath('//*[local-name()="col"]' \
                           '[@hidden="1" or @hidden="true"]').size
        label = labels[name] || File.basename(name, '.xml')
        if rows.positive?
          findings << { type: 'hidden_rows', name: label, count: rows }
        end
        if cols.positive?
          findings << { type: 'hidden_columns', name: label, count: cols }
        end
      end
      findings
    end

    # Part path => the name on the sheet's tab, in workbook order.
    def sheet_names(zip, names, workbook)
      return {} unless names.include?('xl/_rels/workbook.xml.rels')

      targets = relationship_targets(zip)
      workbook.xpath('//*[local-name()="sheet"]').
        each_with_object({}) do |sheet, labels|
          id = sheet.attribute_nodes.find do |node|
            node.name == 'id' &&
              node.namespace&.href.to_s.end_with?('/relationships')
          end&.value
          path = targets[id]
          if path && names.include?(path)
            name = sheet['name']
            labels[path] = if OfficePackage.blank?(name)
                             File.basename(path, '.xml')
                           else
                             name
                           end
          end
        end
    end

    def relationship_targets(zip)
      xml(zip, 'xl/_rels/workbook.xml.rels').
        xpath('//*[local-name()="Relationship"]').to_h do |relation|
          target = relation['Target'].to_s
          path = if target.start_with?('/')
                   target.delete_prefix('/')
                 else
                   File.join('xl', target)
                 end
          [relation['Id'], path]
        end
    end

    def document(zip, names)
      body = xml(zip, 'word/document.xml')
      findings = []
      changes = body.xpath('//*[local-name()="ins" or local-name()="del"]').size
      if changes.positive?
        findings << { type: 'tracked_changes', count: changes }
      end
      hidden = body.xpath('//*[local-name()="vanish"]').size
      findings << { type: 'hidden_text', count: hidden } if hidden.positive?
      if names.include?('word/comments.xml')
        comments = xml(zip, 'word/comments.xml').
                   xpath('//*[local-name()="comment"]').size
        findings << { type: 'comments', count: comments } if comments.positive?
      end
      findings
    end

    def presentation(names)
      notes = names.grep(%r{\Appt/notesSlides/notesSlide\d+\.xml\z}).size
      comments = names.grep(%r{\Appt/comments/}).size
      findings = []
      findings << { type: 'speaker_notes', count: notes } if notes.positive?
      if comments.positive?
        findings << { type: 'comment_files', count: comments }
      end
      findings
    end

    # The author and last editor, as the property's element names them.
    def properties(zip, names)
      return [] unless names.include?('docProps/core.xml')

      core = xml(zip, 'docProps/core.xml')
      %w[creator lastModifiedBy].filter_map do |element|
        value = core.at_xpath("//*[local-name()=\"#{element}\"]")&.
                text.to_s.strip
        next if OfficePackage.blank?(value)

        { type: 'property', name: element, value: value }
      end
    end

    # A part, read through Package and parsed leniently, within the part size
    # limit; a missing part raises OfficePackage::Error.
    def xml(zip, name)
      if zip.size(name) > MAX_PART
        raise Guard::Refused, 'part_too_large_to_parse'
      end

      Nokogiri::XML(zip.read(name), &:nonet)
    end
  end
end
