module Disclosures
  # Applies text and file masks to disclosures. Text masks don't alter images
  # or files, so masked pages are flagged for review; no redaction rows saved.
  module Masking
    # Core's login_link mask, also scheme-less, www., or space after /c/.
    LOGIN_LINK = %r{(?:https?://)?(?:www\.)?
                    #{Regexp.escape(AlaveteliConfiguration.domain)}/c/\s*\S+}xi
    # request-ID-HASH, with spaces or line breaks allowed between its parts.
    REQUEST_ADDRESS = /request\s*-\s*(?:bounce\s*-\s*)?\d+\s*-\s*[a-z0-9]+/i
    # Hyphens Word and others write in place of "-".
    DASHES = /[\u2010\u2011\u2013]/
    # Line breaks at soft/hard hyphens (e.g. Word or pdftotext wrapping).
    SOFT_BREAK = /\u00AD[^\S\n]*\r?\n\s*/
    HYPHEN_BREAK = /-[^\S\n]*\r?\n\s*/
    # Characters that join or split words without showing.
    INVISIBLE = /[\u00AD\u200B-\u200D\u2060\uFEFF]/

    module_function

    # Sign-in links or any reply address; blocks requester auto-publish even
    # in variants missed by masks (Version#always_removed_pages).
    def always_removed?(text)
      text = text.to_s.gsub(DASHES, '-').gsub(SOFT_BREAK, '').
        gsub(HYPHEN_BREAK, '-').gsub(INVISIBLE, '')
      text.match?(LOGIN_LINK) || reply_address?(text)
    end

    # Validates the hash via core's extractor without any DB lookup.
    def reply_address?(text)
      text.scan(REQUEST_ADDRESS).any? do |candidate|
        id, hash = InfoRequest._extract_id_hash_from_email(
          candidate.gsub(/\s+/, '')
        )
        id && hash.to_s.start_with?(InfoRequest.hash_from_id(id))
      end
    end

    # Applies request masks, or public/censor/default masks if the request was
    # deleted (its own reply address can no longer be derived then).
    def apply(text, document)
      clean(masks_for(document).apply(clean(text), 'text/plain'))
    end

    def masks_for(document, view = :public)
      request = document.info_request
      return request.masks_for(view) if request

      case view
      when :admins then MaskSet.none
      when :requester, :pack
        black = RuleCheck.rules_for(document).select(&:black?)
        MaskSet.new(censor_rules: black, masks: [], default_masks: false)
      when :public, :ai
        orange = InfoRequest::Masking.address_masks(document.public_body).
          map { |mask| mask.merge(colour: 'orange') }
        MaskSet.new(censor_rules: RuleCheck.rules_for(document),
                    masks: orange, default_masks: true)
      else
        raise ArgumentError, "no such view of a document's masks: " \
                             "#{view.inspect}"
      end
    end

    # Applies all request masks; callers with a document should use apply.
    def for_request(text, info_request)
      clean(info_request.apply_all_masks(clean(text), 'text/plain',
                                         redactable: nil))
    end

    # Strips control chars, including snippet markers \u0002 and \u0003.
    def clean(text)
      text.to_s.dup.force_encoding('UTF-8').scrub('').tr("\f", "\n").
        gsub(/[\u0000-\u0008\u000B\u000E-\u001F\u007F]/, '')
    end

    def input(bytes, content_type, name)
      case Formats.for(content_type, name, bytes)
      when 'pdf' then [bytes, 'application/pdf']
      when 'text', 'csv'
        type = content_type
        type = 'text/plain' unless AlaveteliTextMasker::TEXT_MASK.include?(type)
        [convert_string_to_utf8(bytes, 'UTF-8').string, type]
      else [bytes, content_type]
      end
    end

    def apply_rules(bytes, content_type:, filename:, rules:, unmasked: nil)
      input_bytes, type = input(bytes, content_type, filename)
      AlaveteliTextMasker.apply_masks(
        input_bytes, type,
        censor_rules: rules, default_masks: false, unmasked: unmasked
      )
    end

    def public_masked_bytes(bytes, attachment, document,
                            content_type: attachment.content_type,
                            filename: attachment.filename)
      return bytes if bytes.blank?
      if content_type == attachment.content_type &&
         attachment.rasterized?
        return bytes
      end

      bytes = Tidy.apply(bytes, content_type, filename)

      format = Formats.for(content_type, filename, bytes)
      return bytes unless RuleRemask::MASKABLE.include?(format)

      input_bytes, type = input(bytes, content_type, filename)
      mask_set = masks_for(document, :public)
      return bytes if mask_set.none?

      unmasked = []
      masked = mask_set.apply(input_bytes, type,
                              masked: true,
                              unmasked: unmasked)
      unmasked -= [AlaveteliTextMasker::UNMASKED_ZIP]
      if unmasked.any?
        raise Error::Refused, _('This file couldn’t be masked for publication.')
      end

      masked.b
    rescue AlaveteliTextMasker::PDFMaskingError, Regexp::TimeoutError => e
      raise Error::Refused,
            _('This file couldn’t be masked for publication: {{reason}}',
              reason: e.message)
    end

    def apply_public_masks!(attachment, document)
      bytes = attachment.body
      return if bytes.blank?

      masked = public_masked_bytes(bytes, attachment, document)
      return if masked.b == bytes.b

      attachment.replace_file!(masked.b, metadata: kept_analysis(attachment))
      attachment.update!(masked_at: Time.zone.now, masking_failed_at: nil)
    end

    # Preserves prior SpreadsheetHold analysis: Tidy only strips metadata.
    def kept_analysis(attachment)
      return unless SpreadsheetHold.spreadsheet?(attachment) &&
                    attachment.file.analyzed?

      attachment.file_blob.metadata.except('identified')
    end
  end
end
