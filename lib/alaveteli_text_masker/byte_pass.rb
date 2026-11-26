module AlaveteliTextMasker
  # Fixed-length byte masker for binary files: replaces emails and censor rules
  # with 'x' to preserve file size.
  class BytePass < Pass
    def apply(text)
      orig_size = text.bytesize
      text = text.dup

      # Skipped on incoming files (default_masks: false).
      mask_emails!(text) unless options[:default_masks] == false

      censor_rules = options[:censor_rules] || []
      redactable = options[:redactable]
      redacted_attribute = options[:redacted_attribute]
      text = censor_rules.reduce(text) do |t, rule|
        unless rule.byte_pattern(t.encoding)
          options[:unmasked]&.push(format(UNMASKED_RULE, id: rule.id))
        end
        after = rule.apply_to_binary(t, redactable: redactable,
                                        redacted_attribute: redacted_attribute)
        options[:matched]&.push(rule) if after != t
        after
      end
      raise "internal error in apply_binary_masks" if text.bytesize != orig_size

      text
    end

    private

    def mask_emails!(text)
      text.gsub!(MySociety::Validate.email_find_regexp) do |email|
        email.gsub(/[^@.]/, 'x')
      end

      # Replace UCS-2 (UTF-16LE) email addresses in MS Office binaries.
      ascii_chars = strip_nul(text)
      emails = ascii_chars.scan(MySociety::Validate.email_find_regexp)

      emails.map! do |email|
        masked = email[0].gsub(/[^@.]/, 'x')
        [email[0].encode('UTF-16LE').force_encoding('US-ASCII'),
         masked.encode('UTF-16LE').force_encoding('US-ASCII')]
      end
      # Each pair is a full pass over the text; already-masked addresses and
      # repeats change nothing.
      emails.uniq!
      emails.reject! { |email, mask| email == mask }

      emails.each do |email, mask|
        text.gsub!(email, mask)
      end
    end

    # Slice binary NUL-dense text (UCS-2, uncompressed PDFs) so gsub/delete
    # does not hold the GVL for seconds and byte slices cannot split UTF-8.
    def strip_nul(text)
      binary = text.b
      nul = binary.count("\0")
      return text if nul.zero?
      if nul * 64 < binary.bytesize
        return binary.delete("\0").force_encoding(text.encoding)
      end

      stripped = String.new(capacity: binary.bytesize,
                            encoding: binary.encoding)
      (0...binary.bytesize).step(NUL_STRIP_SLICE) do |offset|
        stripped << binary.byteslice(offset, NUL_STRIP_SLICE).delete("\0")
      end
      stripped.force_encoding(text.encoding)
    end
  end
end
