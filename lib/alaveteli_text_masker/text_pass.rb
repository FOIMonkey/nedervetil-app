module AlaveteliTextMasker
  # Masks plain text and HTML content using simultaneous span-merging.
  class TextPass < Pass
    REFERENCE = /&(?:[A-Za-z][A-Za-z0-9]{1,31}|#[0-9]{1,7}|#[xX]\h{1,6});/
    LETTER = /\A[\p{L}\p{M}]\z/
    BACKREF = /\\(?:([0-9])|k<([^>]+)>|([&+`'\\]))/
    # Byte offsets avoid O(n) char indexing; length is in chars for tie-breaks.
    Span = Data.define(:start_pos, :end_pos, :length, :priority, :replacement,
                       :rule)

    def apply(text)
      decoded = decode_html_letters(text)
      censor_rules = options[:censor_rules] || []
      spans = collect_spans(decoded, censor_rules)
      record_censor_matches(censor_rules, spans)
      return text if spans.empty?

      masked = rebuild(decoded, merge_spans(spans))
      return text if masked == decoded

      masked
    end

    private

    def collect_spans(decoded, censor_rules)
      spans = []
      priority = 0

      (options[:masks] || []).each do |mask|
        scan_entry(decoded, mask[:to_replace], mask[:replacement].to_s,
                   priority, nil, spans)
        priority += 1
      end

      censor_rules.each do |rule|
        scan_entry(decoded, rule.text_pattern, rule.replacement.to_s,
                   priority, rule, spans)
        priority += 1
      end

      default_masks.each do |mask|
        scan_entry(decoded, mask[:to_replace], mask[:replacement].to_s,
                   priority, nil, spans)
        priority += 1
      end

      (options[:post_masks] || []).each do |mask|
        scan_entry(decoded, mask[:to_replace], mask[:replacement].to_s,
                   priority, nil, spans)
        priority += 1
      end

      spans
    end

    def scan_entry(decoded, pattern, replacement, priority, rule, spans)
      return if pattern.blank?

      if pattern.is_a?(Regexp)
        scan_regexp(decoded, pattern, replacement, priority, rule, spans)
      else
        scan_literal(decoded, pattern.to_s, replacement, priority, rule, spans)
      end
    end

    def scan_regexp(decoded, pattern, replacement, priority, rule, spans)
      decoded.scan(pattern) do
        match = Regexp.last_match
        start_pos, end_pos = match.byteoffset(0)
        next if end_pos == start_pos

        value = expand_replacement(replacement, match)
        spans << Span.new(start_pos, end_pos, match[0].length, priority,
                          value, rule)
      end
    end

    def scan_literal(decoded, pattern, replacement, priority, rule, spans)
      return if pattern.empty?

      each_literal(decoded, pattern) do |start_pos|
        spans << Span.new(start_pos, start_pos + pattern.bytesize,
                          pattern.length, priority, replacement, rule)
      end
    end

    # Avoids String#scan, which raises on invalid-encoding bytes that literal
    # matching tolerates.
    def each_literal(decoded, pattern, &block)
      unless decoded.valid_encoding?
        return each_literal_by_character(decoded, pattern, &block)
      end

      pos = 0
      while (start_pos = decoded.byteindex(pattern, pos))
        yield start_pos
        pos = start_pos + pattern.bytesize
      end
    end

    # String#byteindex rejects offsets after invalid bytes; fall back to char
    # indexing on malformed strings.
    def each_literal_by_character(decoded, pattern)
      pos = 0
      while (start_pos = decoded.index(pattern, pos))
        yield decoded[0...start_pos].bytesize
        pos = start_pos + pattern.length
      end
    end

    def expand_replacement(template, match)
      return template unless template.include?('\\')

      template.gsub(BACKREF) do
        if Regexp.last_match(1)
          match[Regexp.last_match(1).to_i].to_s
        elsif Regexp.last_match(2)
          name = Regexp.last_match(2)
          match.names.include?(name) ? match[name].to_s : ''
        else
          case Regexp.last_match(3)
          when '&' then match[0].to_s
          when '+' then match.captures.compact.last.to_s
          when '`' then match.pre_match
          when "'" then match.post_match
          when '\\' then '\\'
          end
        end
      end
    end

    def merge_spans(spans)
      ordered = spans.sort_by do |span|
        [span.start_pos, -span.length, span.priority]
      end
      merged = []
      ordered.each do |span|
        if merged.empty? || span.start_pos >= merged.last[:end_pos]
          merged << { start_pos: span.start_pos, end_pos: span.end_pos,
                      winner: span }
        else
          group = merged.last
          group[:end_pos] = span.end_pos if span.end_pos > group[:end_pos]
          group[:winner] = span if better_span?(span, group[:winner])
        end
      end
      merged
    end

    def better_span?(candidate, current)
      if candidate.length != current.length
        return candidate.length > current.length
      end

      candidate.priority < current.priority
    end

    def rebuild(decoded, merged)
      out = if decoded.encoding == Encoding::UTF_8 || decoded.ascii_only?
              +''
            else
              String.new(encoding: decoded.encoding)
            end
      cursor = 0
      merged.each do |group|
        out << decoded.byteslice(cursor, group[:start_pos] - cursor)
        out << group[:winner].replacement
        cursor = group[:end_pos]
      end
      out << decoded.byteslice(cursor, decoded.bytesize - cursor)
      out
    end

    def record_censor_matches(censor_rules, spans)
      return if censor_rules.empty?

      matched = {}.compare_by_identity
      spans.each { |span| matched[span.rule] = true if span.rule }
      redactable = options[:redactable]
      redacted_attribute = options[:redacted_attribute]

      censor_rules.each do |rule|
        hit = matched.key?(rule)
        rule.record_match(redactable, redacted_attribute, matched: hit)
        options[:matched]&.push(rule) if hit
      end
    end

    # Decode letter character references while leaving markup entities intact.
    def decode_html_letters(text)
      return text unless content_type == 'text/html' && text.match?(REFERENCE)

      utf8 = text.dup.force_encoding(Encoding::UTF_8)
      return text unless utf8.valid_encoding?

      entities = HTMLEntities.new(:expanded)
      utf8.gsub(REFERENCE) do |reference|
        letter = entities.decode(reference)
        letter.match?(LETTER) ? letter : reference
      end
    end
  end
end
