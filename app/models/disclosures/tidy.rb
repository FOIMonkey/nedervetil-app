module Disclosures
  # Strips non-essential Office metadata via OfficePackage::Tidy before public
  # masking when DISCLOSURES_REMOVE_OFFICE_METADATA is enabled. See doc/FORK.md.
  module Tidy
    # A file that can't be tidied doesn't become a document.
    Refused = Class.new(Error::Refused)

    module_function

    def on?
      AlaveteliConfiguration.disclosures_remove_office_metadata == true
    end

    # Runs ZipGuard first so archive refusals match the rest of the pipeline.
    def apply(bytes, content_type, filename)
      return bytes unless on? && tidied?(bytes, content_type, filename)

      OfficePackage::Isolated.read(%w[guard_unpack tidy],
                                   bytes: bytes) do |read|
        ZipGuard.checked!(read, unpack: true)
        read.value('tidy')
      end
    rescue ZipGuard::Refused => e
      raise Refused, e.message
    rescue Zip::Error
      raise Refused, _(Formats::REFUSED)
    rescue OfficePackage::Error => e
      raise Refused,
            _('This site couldn’t remove the hidden data from this file ' \
              '({{reason}}), so it can’t become a document.',
              reason: e.message)
    end

    # .xls is left as it came, as the renderer leaves it unguarded.
    def tidied?(bytes, content_type, filename)
      Formats::MAIN_PART.key?(Formats.for(content_type, filename, bytes)) &&
        !Formats.legacy_office?(content_type, filename)
    end
  end
end
