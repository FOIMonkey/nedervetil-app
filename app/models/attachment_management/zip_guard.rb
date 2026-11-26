require 'zip'

module AttachmentManagement
  # OfficePackage::Guard, which checks an Office Open XML file's zip before
  # anything parses or converts it, with its refusals in the site's words.
  module ZipGuard
    Refused = Class.new(StandardError)

    MAX_ENTRIES = OfficePackage::MAX_ENTRIES
    MAX_TOTAL = OfficePackage::MAX_TOTAL
    MAX_RATIO = OfficePackage::MAX_RATIO
    RATIO_FROM = OfficePackage::RATIO_FROM
    MAX_SHEETS = OfficePackage::Guard::MAX_SHEETS
    MAX_SLIDES = OfficePackage::Guard::MAX_SLIDES
    MAX_PART = OfficePackage::MAX_PART

    REASONS = {
      'unpacked' => ->(values) {
        _('over {{size}} unpacked', size: human(values[:size]))
      },
      'archive' => ->(values) { values[:message] },
      'parts' => ->(values) {
        _('more than {{count}} parts', count: values[:count])
      },
      'listed_twice' => ->(_values) { _('parts listed twice') },
      'sheets' => ->(values) {
        _('more than {{count}} sheets', count: values[:count])
      },
      'slides' => ->(values) {
        _('more than {{count}} slides', count: values[:count])
      },
      'part_size' => ->(values) {
        _('a part over {{size}}', size: human(values[:size]))
      },
      'part_larger' => ->(_values) { _('a part larger than the archive says') },
      'ratio' => ->(values) {
        _('a part compressed more than {{ratio}} to 1', ratio: values[:ratio])
      },
      'doctype' => ->(_values) { _('a part that declares a DOCTYPE') },
      'not_well_formed' => ->(_values) {
        _('a part that is not well-formed XML')
      }
    }.freeze

    module_function

    # unpack: inflates every part to verify declared sizes before LibreOffice
    # reads the archive directly; Zip::Error propagates to callers.
    def check!(path, unpack: false)
      worded { OfficePackage::Guard.check!(path, unpack: unpack) }
    end

    def checked!(read, unpack: false)
      worded { read.value(unpack ? 'guard_unpack' : 'guard') }
    end

    def count!(source)
      worded { OfficePackage::Guard.count!(source) }
    end

    def read(entry, limit = MAX_PART)
      worded { OfficePackage::Guard.read(entry, limit) }
    end

    def refused(refusal)
      if refusal.reason == 'part_too_large_to_parse'
        return Refused.new('a part over the size limit')
      end

      Refused.new(
        _('This file is too large or too complex to process here ' \
          '({{reason}}).',
          reason: REASONS.fetch(refusal.reason).call(refusal.values))
      )
    end

    def worded
      yield
    rescue OfficePackage::Guard::Refused => e
      raise refused(e)
    end

    def human(bytes)
      ActiveSupport::NumberHelper.number_to_human_size(bytes)
    end
  end
end
