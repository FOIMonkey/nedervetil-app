module AttachmentManagement
  class Replacement
    # The rule sets that apply to a file, and putting one on bytes in memory.
    module Masks
      module_function

      def black_set(attachment, document)
        return Disclosures::Masking.masks_for(document, :requester) if document
        if attachment.info_request
          return attachment.info_request.masks_for(:requester)
        end

        MaskSet.none
      end

      def public_set(attachment, document)
        return Disclosures::Masking.masks_for(document, :public) if document
        if attachment.info_request
          return attachment.info_request.masks_for(:public)
        end

        MaskSet.none
      end

      # Returns the masked bytes, whether a black rule matched, and the parts
      # that couldn't be masked.
      def apply(bytes, mask_set, content_type:, filename:)
        input_bytes, type = Disclosures::Masking.input(
          bytes, content_type, filename
        )
        unmasked = []
        matched = []
        masked = mask_set.apply(input_bytes, type,
                                masked: true,
                                unmasked: unmasked,
                                matched: matched)
        unmasked -= [AlaveteliTextMasker::UNMASKED_ZIP]
        [masked.b, matched.any?(&:black?), unmasked]
      end
    end
  end
end
