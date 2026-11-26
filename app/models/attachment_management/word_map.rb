module AttachmentManagement
  # Builds and masks per-page PDF word bounding-box maps for the box editor.
  # Uses stored PDF text only (no live file reads or OCR).
  module WordMap
    MAX_WORDS = 5_000
    MAX_TEXT = 100_000

    module_function

    def state(value)
      { state: value, words: [] }
    end

    # Clamps boxes to 0..1 (dropping off-page words, which the editor rejects)
    # and refuses the whole page on word/text limits rather than truncating.
    def of(found)
      words = []
      characters = 0
      found.each do |word|
        text = Disclosures::Masking.clean(word[:text]).strip
        box = within_page(word[:box])
        next if text.empty? || box.nil?

        characters += text.size
        if text.size > 500 || characters > MAX_TEXT || words.size >= MAX_WORDS
          return state('limit')
        end

        words << word.merge(id: words.size.to_s, text: text, box: box)
      end
      words.empty? ? state('unreadable') : { state: 'ready', words: words }
    end

    def within_page(box)
      placed = box.map { |value| value.clamp(0.0, 1.0).round(6) }
      placed if placed[2] > placed[0] && placed[3] > placed[1]
    end

    def for_editor(map, info_request, requester:, name_consent: false)
      visible = masked(map, info_request)
      personal = PersonalSuggestions.for(map, visible: visible, user: requester,
                                              name_consent: name_consent)
      visible.merge(personal: personal)
    end

    def text(words)
      words.group_by { |word| word[:line] }.values.
        map { |line| line.map { |word| word[:text] }.join(' ') }.join("\n")
    end

    # Drops masked words/lines, then re-checks the full kept text so cross-line
    # or context-dependent rules withhold the entire map fail-closed.
    def masked(result, info_request)
      return result unless result[:state] == 'ready'
      return state('unavailable') unless info_request

      apply = ->(value) do
        Disclosures::Masking.for_request(value, info_request)
      end
      words = result[:words]
      return result if apply.call(text(words)) == text(words)

      kept = words.reject { |word| apply.call(word[:text]) != word[:text] }
      kept = kept.group_by { |word| word[:line] }.values.reject do |line|
        apply.call(text(line)) != text(line)
      end.flatten
      if kept.empty? || apply.call(text(kept)) != text(kept)
        return state('masked')
      end

      { state: 'partial', words: kept }
    rescue StandardError => e
      # try: a caller's stand-in for the request may have no id.
      Rails.logger.warn('attachment_word_map_masking_failed ' \
                        "info_request_id=#{info_request.try(:id)} #{e.class}")
      state('unavailable')
    end
  end
end
