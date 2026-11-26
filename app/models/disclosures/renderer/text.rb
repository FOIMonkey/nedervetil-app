module Disclosures
  class Renderer
    # Splits plain text or HTML attachments into indexed page parts.
    class Text < Kind
      private

      def pages(path, _dir)
        text = Sheets.utf8(File.binread(path))
        if html?
          outcome.notes['hiding_styles'] = true if Renderer.hiding_styles?(text)
          text = Renderer.html_text(text)
        end
        parts = if text.empty?
                  ['']
                else
                  (0...text.length).step(TEXT_PART).
                    map { |start| text[start, TEXT_PART] }
                end
        parts.each_with_index do |part, index|
          label = parts.size > 1 ? "Part #{index + 1}" : 'Text'
          checked = text[index * TEXT_PART, TEXT_PART + PART_OVERLAP].to_s
          add_text_page(index + 1, label, 'text', part, 'plain',
                        checked: checked)
        end
        outcome.page_count = parts.size
      end

      def html?
        Formats.html?(attachment.content_type, "file#{safe_extension}")
      end
    end
  end
end
