module Disclosures
  # Scores hidden Office content (OfficePackage::Hidden) as :high or :low.
  # Hidden sheets, unreadable items, personal data, and high text volume are
  # :high and block requester auto-publish. See doc/FORK.md.
  module HiddenRisk
    DISTINCT = 50
    MAX_TEXT = 4.megabytes
    ALWAYS = %w[hidden_sheet very_hidden_sheet].freeze
    PAIRED = %w[named_ranges external_links].freeze

    Finding = Struct.new(:label, :level) do
      def high?
        level == :high
      end
    end

    module_function

    # read: optional OfficePackage::Isolated read that requested 'hidden'.
    def findings(path, document, read: nil)
      unless read
        return OfficePackage::Isolated.read(%w[hidden], path: path) do |own|
          findings(path, document, read: own)
        end
      end

      items = read.value('hidden')
      paired = paired?(items, read, document)
      items.filter_map do |item|
        next if item.type == 'title' && !names_requester?(item, document)
        if PAIRED.include?(item.type)
          next paired ? Finding.new(label(item), :high) : nil
        end

        Finding.new(label(item), level(item, document))
      end
    rescue OfficePackage::Error
      [Finding.new(_('The file couldn’t be opened to list what it carries.'),
                   :high)]
    end

    def level(item, document)
      return :high if ALWAYS.include?(item.type)
      return :high unless item.readable
      return :low if item.texts.empty?

      high?(item.texts, document) ? :high : :low
    end

    def high?(texts, document)
      texts = Array(texts).map { |text| text.to_s.strip }.reject(&:empty?)
      return false if texts.empty?

      distinct = texts.uniq
      return true if distinct.size >= DISTINCT

      joined = texts.join("\n")
      joined.bytesize > MAX_TEXT ||
        personal?(joined, document, pii_text: distinct.join("\n"))
    end

    def personal?(text, document, pii_text: nil)
      cleaned = Masking.clean(text)
      return true if cleaned.match?(MySociety::Validate.email_find_regexp)

      return true if Masking.apply(cleaned, document) != cleaned

      user = document.requester
      return true if user.present? && Checks.names?(user, cleaned)
      return false unless PiiCheck.enabled?

      PiiCheck.call(pii_text ? Masking.clean(pii_text) : cleaned) != :clear
    rescue Regexp::TimeoutError
      true
    end

    def paired?(items, read, document)
      return false unless PAIRED.all? { |type| items.any? { _1.type == type } }

      texts = read.value('content_texts')
      joined = texts.join("\n").byteslice(0, MAX_TEXT)
      pii_text = PiiCheck.deduplicated(texts).join("\n").byteslice(0, MAX_TEXT)
      personal?(joined, document, pii_text: pii_text)
    end

    def names_requester?(item, document)
      user = document.requester
      user.present? && Checks.names?(user, item.texts.join("\n"))
    end

    # Returns plain strings so views escape untrusted file values exactly once.
    def label(item)
      values = { name: item.name, sheet: item.name, count: item.count }
      text = case item.type
             when 'hidden_sheet'
               PlainTextTranslation._('Hidden sheet: {{name}}', values)
             when 'very_hidden_sheet'
               PlainTextTranslation._('Very hidden sheet: {{name}}', values)
             when 'hidden_rows'
               PlainTextTranslation.n_(
                 '{{sheet}}: {{count}} hidden row',
                 '{{sheet}}: {{count}} hidden rows', item.count, values
               )
             when 'hidden_columns'
               PlainTextTranslation.n_(
                 '{{sheet}}: {{count}} hidden column range',
                 '{{sheet}}: {{count}} hidden column ranges', item.count,
                 values
               )
             when 'pivot_caches'
               _('Pivot table caches (they can hold all the data behind a ' \
                 'table)')
             when 'data_model' then _('A data model')
             when 'named_ranges'
               n_('{{count}} named range', '{{count}} named ranges',
                  item.count, count: item.count)
             when 'external_links' then _('Links to other workbooks')
             when 'hidden_text'
               n_('Hidden text in the Word file ({{count}} passage)',
                  'Hidden text in the Word file ({{count}} passages)',
                  item.count, count: item.count)
             when 'building_blocks'
               n_('{{count}} stored building block (text kept for reuse)',
                  '{{count}} stored building blocks (text kept for reuse)',
                  item.count, count: item.count)
             when 'hidden_slides'
               n_('{{count}} hidden slide', '{{count}} hidden slides',
                  item.count, count: item.count)
             when 'off_slide_text'
               n_('Text placed off the slide on {{count}} slide',
                  'Text placed off the slide on {{count}} slides',
                  item.count, count: item.count)
             when 'speaker_notes'
               n_('Speaker notes on {{count}} slide',
                  'Speaker notes on {{count}} slides', item.count,
                  count: item.count)
             when 'chart_data' then _('Charts with their own copy of the data')
             when 'embedded_files'
               n_('{{count}} embedded file', '{{count}} embedded files',
                  item.count, count: item.count)
             when 'macros' then _('Macros (Visual Basic code)')
             when 'title'
               PlainTextTranslation._(
                 'Title in document properties: {{value}}',
                 value: item.texts.first.to_s.truncate(80)
               )
             else item.type.to_s.tr('_', ' ')
             end
      return text.to_str if item.readable

      PlainTextTranslation._(
        '{{what}} (this site can’t read what’s in it)', what: text
      )
    end
  end
end
