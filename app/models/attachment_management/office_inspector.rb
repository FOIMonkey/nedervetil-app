module AttachmentManagement
  # A prompt for the person reviewing the file, not a guarantee: older binary
  # formats (.doc, .xls) and OpenDocument files are not inspected.
  module OfficeInspector
    PROPERTIES = {
      'creator' => -> { _('Author') },
      'lastModifiedBy' => -> { _('Last modified by') }
    }.freeze

    LABELS = {
      'hidden_sheet' => ->(finding) {
        PlainTextTranslation._('Hidden sheet: {{name}}', name: finding[:name])
      },
      'very_hidden_sheet' => ->(finding) {
        PlainTextTranslation._('Very hidden sheet: {{name}}',
                               name: finding[:name])
      },
      'hidden_rows' => ->(finding) {
        PlainTextTranslation.n_(
          '{{sheet}}: {{count}} hidden row',
          '{{sheet}}: {{count}} hidden rows', finding[:count],
          sheet: finding[:name], count: finding[:count]
        )
      },
      'hidden_columns' => ->(finding) {
        PlainTextTranslation.n_(
          '{{sheet}}: {{count}} hidden column range',
          '{{sheet}}: {{count}} hidden column ranges', finding[:count],
          sheet: finding[:name], count: finding[:count]
        )
      },
      'cell_comments' => ->(finding) {
        n_('{{count}} cell comment', '{{count}} cell comments',
           finding[:count], count: finding[:count])
      },
      'tracked_changes' => ->(finding) {
        n_('{{count}} tracked change', '{{count}} tracked changes',
           finding[:count], count: finding[:count])
      },
      'hidden_text' => ->(finding) {
        _('{{count}} runs of hidden text', count: finding[:count])
      },
      'comments' => ->(finding) {
        n_('{{count}} comment', '{{count}} comments', finding[:count],
           count: finding[:count])
      },
      'speaker_notes' => ->(finding) {
        n_('Speaker notes on {{count}} slide',
           'Speaker notes on {{count}} slides', finding[:count],
           count: finding[:count])
      },
      'comment_files' => ->(finding) {
        n_('{{count}} comment file', '{{count}} comment files',
           finding[:count], count: finding[:count])
      },
      'embedded_files' => ->(finding) {
        n_('{{count}} embedded file', '{{count}} embedded files',
           finding[:count], count: finding[:count])
      },
      'property' => ->(finding) {
        PlainTextTranslation._(
          '{{label}} in document properties: {{value}}',
          label: PROPERTIES.fetch(finding[:name]).call,
          value: finding[:value]
        )
      }
    }.freeze

    def self.findings(path)
      OfficePackage::Isolated.read(%w[guard inspector], path: path) do |read|
        findings_in(read)
      end
    end

    def self.findings_in(read)
      ZipGuard.checked!(read)
      read.value('inspector').map { |finding| label(finding) }
    rescue ZipGuard::Refused, OfficePackage::Refused,
           OfficePackage::Guard::Refused
      [_('Too large or too complex to open here, ' \
         'so its hidden content could not be listed.')]
    rescue Zip::Error, OfficePackage::Error, Nokogiri::XML::SyntaxError
      [_('Not an Office Open XML file, ' \
         'so its hidden content could not be listed.')]
    end

    def self.label(finding)
      LABELS.fetch(finding[:type]).call(finding)
    end
  end
end
