module AttachmentManagement
  # Visible words may be referenced; masked matches return generic geometry
  # only. Never serialize profile values, rule labels or masked page text.
  module PersonalSuggestions
    MAX_MATCHES = 100

    module_function

    def for(map, user:, name_consent: false, visible: map)
      empty = { state: 'unavailable',
                items: [],
                limited: false,
                name_consent: name_consent.present? }
      unless user && map[:state].in?(%w[ready partial]) &&
             visible[:state].in?(%w[ready partial masked])
        return empty
      end

      text = +''
      previous = nil
      spans = map[:words].map do |word|
        # Do not join a phrase across a gap left by a site masking rule.
        text <<
          (previous && word[:id].to_i != previous[:id].to_i + 1 ? "\0" : ' ')
        start = text.length
        text << Disclosures::Checks.even(word[:text])
        previous = word
        { start: start, end: text.length, word: word }
      end
      candidates = []
      limited = false
      Disclosures::Checks.rules_for(user).each do |pattern, _label, kind|
        count = 0
        text.to_enum(:scan, pattern).each do
          match = Regexp.last_match
          count += 1
          if count > MAX_MATCHES
            limited = true
            break
          end
          selected = spans.each_index.select do |i|
            spans[i][:end] > match.begin(:name) &&
              spans[i][:start] < match.end(:name)
          end
          next if selected.empty?

          candidates << { first: selected.first,
                          last: selected.last,
                          kinds: [kind] }
        end
      end
      merged = []
      candidates.sort_by { |hit| [hit[:first], hit[:last]] }.each do |hit|
        if merged.last && hit[:first] <= merged.last[:last]
          merged.last[:last] = [merged.last[:last], hit[:last]].max
          merged.last[:kinds] |= hit[:kinds]
        else
          merged << hit
        end
      end
      limited ||= merged.size > MAX_MATCHES
      allowed = visible[:words].map { |word| word[:id] }
      items = merged.first(MAX_MATCHES).map do |hit|
        words = spans[hit[:first]..hit[:last]].map { |span| span[:word] }
        if words.all? { |word| allowed.include?(word[:id]) }
          { words: words.map { |word| word[:id] }, kinds: hit[:kinds] }
        else
          # Only generic kinds and geometry from visible pixels may leave.
          { areas: areas(words),
            kinds: hit[:kinds],
            cross_line: words.map { |word| word[:line] }.uniq.size > 1 }
        end
      end
      { state: 'ready',
        items: items,
        limited: limited,
        name_consent: name_consent.present? }
    rescue StandardError => e
      # try: a caller's stand-in for the account may have no id.
      Rails.logger.warn('attachment_personal_suggestions_failed ' \
                        "user_id=#{user.try(:id)} #{e.class}")
      empty
    end

    def areas(words)
      groups = []
      words.each do |word|
        previous = groups.last&.last
        if starts_new_area?(word, previous)
          groups << [word]
        else
          groups.last << word
        end
      end
      groups.map do |group|
        box = [group.map { |word| word[:box][0] }.min - 0.002,
               group.map { |word| word[:box][1] }.min - 0.002,
               group.map { |word| word[:box][2] }.max + 0.002,
               group.map { |word| word[:box][3] }.max + 0.002]
        box.map { |value| value.clamp(0, 1).round(6) }
      end
    end

    def starts_new_area?(word, previous)
      !previous || word[:line] != previous[:line] ||
        word[:box][0] - previous[:box][2] >
          [0.02, (word[:box][3] - word[:box][1]) * 2].max
    end
  end
end
