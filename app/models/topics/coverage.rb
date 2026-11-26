module Topics
  # Reports how many topic-nation questions link directly to a table/lookup
  # dataset (`bin/rails runner 'puts Topics::Coverage.summary'`).
  module Coverage
    module_function

    def rows
      Topic.all.flat_map do |topic|
        topic.questions.flat_map do |question|
          Topic::NATIONS.keys.select { |nation| question.for?(nation) }.
            map { |nation| [topic, question, nation] }
        end
      end
    end

    def direct?(question, nation)
      !!question.dataset_for(nation)&.direct?
    end

    def area?(question, nation)
      direct?(question, nation) &&
        question.dataset_for(nation).area_url.present?
    end

    def count(rows)
      [
        rows.count { |_, question, nation| direct?(question, nation) },
        rows.size
      ]
    end

    def by(rows, &key)
      rows.group_by(&key).transform_values { |group| count(group) }
    end

    def summary
      all = rows
      direct, total = count(all)
      area = all.count { |_, question, nation| area?(question, nation) }
      whole = all.count do |_, question, nation|
        direct?(question, nation) && !question.partial
      end
      lines = ["Direct pointers: #{direct}/#{total} " \
               "(#{percent(direct, total)}); " \
               "answering the whole question: #{whole}/#{total} " \
               "(#{percent(whole, total)}); opening at an area: #{area}"]
      lines += by(all) { |_, _, nation| nation }.
               map { |nation, pair| "  #{nation}: #{fraction(pair)}" }
      lines += by(all) { |topic, _, _| topic.slug }.
               map { |slug, pair| "  #{slug}: #{fraction(pair)}" }
      lines.join("\n")
    end

    def percent(part, whole)
      if whole.zero?
        '0%'
      else
        "#{(100.0 * part / whole).round}%"
      end
    end

    def fraction((part, whole))
      "#{part}/#{whole} (#{percent(part, whole)})"
    end
  end
end
