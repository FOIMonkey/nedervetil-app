module AlaveteliTextMasker
  # A PDF, masked by its text as a viewer draws it.
  class PDFPass < Pass
    def apply(text)
      censor_rules = options[:censor_rules] || []
      masked, report = redact_pdf(text, censor_rules)
      options[:unmasked]&.concat(Array(report['unmasked_parts']))
      censor_rules.each_with_index do |rule, i|
        hit = report['rules_matched'].include?(i)
        rule.record_match(options[:redactable], options[:redacted_attribute],
                          matched: hit)
        options[:matched]&.push(rule) if hit
      end
      # A file masked before keeps its bytes unless a rule changed it.
      return text if options[:masked] && !report['changed']

      masked
    end

    def rules(censor_rules)
      censor_rules.map(&:pdf_rule) + pdf_masks
    end

    private

    # Raises PDFMaskingError rather than hand back a PDF it couldn't mask.
    def redact_pdf(text, censor_rules)
      pdf_rules = rules(censor_rules)
      PDFRedactor.redact(text, pdf_rules, ocr: ocr_pdf?(censor_rules))
    rescue Regexp::TimeoutError
      raise
    rescue PDFRedactor::PasswordRequired
      # Masking can't reach it, so it's served as it came, and recorded.
      Rails.logger.info(
        "[masking] PDF needs a password; served as it is " \
        "#{AlaveteliSandbox.context}"
      )
      [text, { 'rules_matched' => [], 'changed' => false,
               'unmasked_parts' => [UNMASKED_PDF] }]
    rescue StandardError => e
      Rails.logger.warn(
        "[masking] PDF not masked: #{e.class}: " \
        "#{e.message.lines.first&.strip} #{AlaveteliSandbox.context}"
      )
      raise PDFMaskingError, "#{e.class}: #{e.message}"
    end

    def pdf_masks
      ((options[:masks] || []) + default_masks).filter_map do |mask|
        pattern = mask[:to_replace]
        next if pattern.blank?

        unless pattern.is_a?(Regexp)
          pattern = Regexp.new(Regexp.escape(pattern.to_s))
        end
        PDFRedactor::Rule.new(pattern, false)
      end
    end

    def ocr_pdf?(censor_rules)
      censor_rules.any? { |rule| OCR_RULE_TYPES.include?(rule.censorable_type) }
    end
  end
end
