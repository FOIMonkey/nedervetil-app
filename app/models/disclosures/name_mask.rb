module Disclosures
  # Masks the requester's name and email in place on a PDF or plain-text file.
  module NameMask
    CHANGE = 'name_mask'.freeze
    SPACE = "[\\s#{PDFRedactor::GAP}#{PDFRedactor::LINE}]+".freeze
    HIDDEN = '[redacted]'.freeze

    module_function

    def maskable?(attachment, format = nil, document: nil)
      return false unless stored_file?(attachment)
      return false if attachment.rasterized?

      format ||= Formats.declared(attachment.content_type, attachment.filename)
      format == 'pdf' || attachment.main_body_part? ||
        document&.source_kind == 'email_text'
    end

    def hide_for_requester!(attachment, user:, document:)
      if ReviewSubmission.required?(document)
        apply!(attachment, user: user, document: document, publish: false)
        ReviewSubmission.submit!(document, user: user)
      else
        apply!(attachment, user: user, document: document, publish: true)
      end
      if ReviewSubmission.pending?(document.reload)
        _('Your name was hidden. An admin will check it before it goes public.')
      else
        _('Your name was hidden and the document is now public.')
      end
    end

    def apply!(attachment, user:, document: nil, publish: true)
      refuse_unless_redactable!(attachment, user)

      bytes = attachment.body
      format = Formats.for(attachment.content_type, attachment.filename, bytes)
      unless maskable?(attachment, format, document: document)
        raise Error::Refused,
              _('This file’s name can’t be hidden automatically.')
      end

      masked, report = if publish
                         hide_for_publication(bytes, format, user,
                                              attachment, document)
                       else
                         hide(bytes, format, user)
                       end

      save_masked!(attachment, masked, user, document)
      publish_masked!(attachment, user, document) if publish

      report
    end

    def stored_file?(attachment)
      attachment&.file&.attached? && !attachment.erased?
    end

    def refuse_unless_redactable!(attachment, user)
      if attachment.erased? || !attachment.file.attached?
        raise Error::Refused, _('This file can’t be redacted.')
      end
      if attachment.black_masked? &&
         !Ability.new(user).can?(:admin, attachment.info_request)
        raise Error::Refused, _('An admin must handle redactions on this file.')
      end
    end

    def save_masked!(attachment, masked, user, document)
      attachment.replace_file!(masked)
      attachment.update!(masked_at: Time.zone.now, masking_failed_at: nil)
      document.log!('name_masked', user: user) if document
    end

    def publish_masked!(attachment, user, document)
      if document
        RequesterPublication.publish_or_queue!(document, user)
      else
        attachment.make_public!
      end
    end

    def hide(bytes, format, user)
      format == 'pdf' ? redact(bytes, user) : redact_text(bytes, user)
    end

    def hide_for_publication(bytes, format, user, attachment, document)
      mask_set = public_mask_set(attachment, document)
      return hide(bytes, format, user) if mask_set.none?

      if format == 'pdf'
        redact_pdf_for_publication(bytes, user, attachment, mask_set)
      else
        redact_text_for_publication(bytes, user, attachment, mask_set)
      end
    end

    def public_mask_set(attachment, document)
      return Masking.masks_for(document, :public) if document
      if attachment.info_request
        return attachment.info_request.masks_for(:public)
      end

      MaskSet.none
    end

    def redact_text_for_publication(bytes, user, attachment, mask_set)
      text = convert_string_to_utf8(bytes.dup, 'UTF-8').string
      name_rules = rules(user)
      unless name_rules.any? { |rule| text.match?(rule.re) }
        raise Error::Refused, _('The name wasn’t found in the file’s text.')
      end

      name_masks = name_rules.map do |rule|
        { to_replace: rule.re, replacement: HIDDEN }
      end
      masked = AlaveteliTextMasker.apply_masks(
        text, 'text/plain',
        masks: mask_set.masks,
        censor_rules: mask_set.censor_rules,
        default_masks: mask_set.default_masks,
        post_masks: name_masks,
        redactable: attachment,
        redacted_attribute: :body
      )
      [masked.b, { 'engine' => CHANGE }]
    rescue Regexp::TimeoutError => e
      raise Error::Refused,
            _('This file couldn’t be masked for publication: {{reason}}',
              reason: e.message)
    end

    def redact_pdf_for_publication(bytes, user, attachment, mask_set)
      public_rules = AlaveteliTextMasker.pdf_rules(
        mask_set.censor_rules,
        masks: mask_set.masks,
        default_masks: mask_set.default_masks
      )
      name_rules = rules(user)
      all_rules = public_rules + name_rules
      masked, report = PDFRedactor.redact(bytes, all_rules,
                                          ocr: false, final_scan: true)
      refuse_if_parts_unmasked!(report)
      record_rule_matches(mask_set.censor_rules, attachment, report)
      name_range = (public_rules.size...all_rules.size)
      unless name_hidden?(report, name_range, bytes, name_rules)
        raise Error::Refused, _('The name wasn’t found in the file’s text.')
      end

      [masked, summary(report)]
    rescue PDFRedactor::PasswordRequired
      raise Error::Refused, _('This file couldn’t be masked for publication.')
    rescue PDFRedactor::Error, Regexp::TimeoutError => e
      raise Error::Refused,
            _('This file couldn’t be masked for publication: {{reason}}',
              reason: e.message)
    end

    def refuse_if_parts_unmasked!(report)
      unmasked = Array(report['unmasked_parts']) -
                 [AlaveteliTextMasker::UNMASKED_ZIP]
      return unless unmasked.any?

      raise Error::Refused, _('This file couldn’t be masked for publication.')
    end

    # PDFRedactor indexes matches by rule position; censor_rules come first.
    def record_rule_matches(censor_rules, attachment, report)
      matched_indices = Array(report['rules_matched'])
      censor_rules.each_with_index do |rule, i|
        rule.record_match(attachment, :body,
                          matched: matched_indices.include?(i))
      end
    end

    # A public rule covering the name suppresses name_rules matches, so also
    # accept a changed PDF that originally contained the name.
    def name_hidden?(report, name_range, bytes, name_rules)
      Array(report['rules_matched']).any? { |i| name_range.cover?(i) } ||
        (report['changed'] && pdf_had_name?(bytes, name_rules))
    end

    def summary(report)
      report.slice('matches', 'notes', 'rules_matched').
        merge('engine' => CHANGE)
    end

    def pdf_had_name?(bytes, name_rules)
      PDFRedactor::FinalScan.check!(bytes, name_rules)
      false
    rescue PDFRedactor::Matched
      true
    rescue StandardError => e
      Rails.logger.warn("name_mask_pdf_scan_failed #{e.class}")
      false
    end

    def redact_text(bytes, user)
      text = convert_string_to_utf8(bytes.dup, 'UTF-8').string
      name_rules = rules(user)
      unless name_rules.any? { |rule| text.match?(rule.re) }
        raise Error::Refused, _('The name wasn’t found in the file’s text.')
      end

      name_masks = name_rules.map do |rule|
        { to_replace: rule.re, replacement: HIDDEN }
      end
      masked = AlaveteliTextMasker.apply_masks(
        text, 'text/plain', masks: name_masks, default_masks: false
      )
      [masked.b, { 'engine' => CHANGE }]
    rescue Regexp::TimeoutError => e
      raise Error, e.message
    end

    def redact(bytes, user)
      masked, report = PDFRedactor.redact(bytes, rules(user),
                                          ocr: false, final_scan: true)
      if report['rules_matched'].empty?
        raise Error::Refused, _('The name wasn’t found in the file’s text.')
      end

      [masked, summary(report)]
    rescue PDFRedactor::Error, Regexp::TimeoutError => e
      raise Error, e.message
    end

    def rules(user)
      sources = []
      email = Checks.even(user.email).strip
      sources << tolerant(email) if email.present?
      forms = Checks.name_forms(Checks.names_of(user), space: SPACE) do |text|
        tolerant(text)
      end
      sources.concat(
        forms.map do |form|
          [form.before && "#{form.before}\\K", form.name, form.after].join
        end
      )
      sources.map do |source|
        PDFRedactor::Rule.new(
          /(?<![[:alnum:]])#{source}(?![[:alnum:]])/i, true
        )
      end
    end

    def tolerant(text)
      PDFRedactor.tolerant(text, true).source.
        gsub("'", "[#{Checks::QUOTES}']")
    end
  end
end
