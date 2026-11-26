module AlaveteliTextMasker
  # An archive, or a document stored as one: it goes out as it came.
  class ArchivePass < Pass
    def apply(text)
      record
      text
    end

    private

    # Byte pass cannot mask compressed entries; record for admins and log when
    # censor rules were active so silence isn't mistaken for redaction.
    def record
      options[:unmasked]&.push(UNMASKED_ZIP)
      return if Array(options[:censor_rules]).empty?

      Rails.logger.info(
        "[masking] #{content_type} is an archive the byte pass cannot " \
        "mask; served as it is #{AlaveteliSandbox.context}"
      )
    end
  end
end
