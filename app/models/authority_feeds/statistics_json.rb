module AuthorityFeeds
  # The Scottish Information Commissioner's figures: authorities keyed by
  # their sic:<value> tag, a Scotland-wide row, every year.
  class StatisticsJson
    METRICS = %w[
      requests on_time late no_reply full some none not_held
      neither_confirm_nor_deny refused
    ].freeze

    def initialize(text, feed)
      @text = text.to_s
      @feed = feed
    end

    def result
      @result ||= read
    end

    private

    def read
      data = JSON.parse(@text)
      unless data.is_a?(Hash) && data['authorities'].is_a?(Hash)
        return failed('This isn’t the statistics file (no "authorities").')
      end

      ids = body_ids_by_tag(data['authorities'].keys)
      rows = sector_rows(data['scotland'])
      notes = {}
      unmatched = []
      data['authorities'].each do |tag, authority|
        unless ids[tag]
          unmatched << [authority['name'] || tag, 1]
          next
        end
        ids[tag].each do |id|
          notes[id] = authority['note'] if authority['note'].present?
          rows.concat(year_rows(authority['years'],
                                Figure.scope_key_for(body_id: id), id))
        end
      end
      before = Figure.where(authority_feed_id: @feed.id).count
      Result.new(rows: rows,
                 problems: [],
                 existing_count: [before, rows.size].min,
                 unmatched: unmatched,
                 notes: notes)
    rescue JSON::ParserError => e
      failed("Not a readable JSON file (#{e.message.first(80)}).")
    end

    def body_ids_by_tag(tags)
      HasTagString::HasTagStringTag.
        where(model_type: 'PublicBody', name: 'sic',
              value: tags).
        pluck(:value, :model_id).group_by(&:first).
        transform_values { |pairs| pairs.map(&:last) }
    end

    def sector_rows(years)
      year_rows(years, Figure.scope_key_for(sector: 'scotland'), nil)
    end

    def year_rows(years, scope_key, body_id)
      (years || {}).flat_map do |period, figures|
        METRICS.filter_map do |metric|
          value = figures[metric]
          if value.is_a?(Numeric)
            { scope_key: scope_key,
              public_body_id: body_id,
              period: period,
              metric: metric,
              value: value }
          end
        end
      end
    end

    def failed(message)
      Result.new(rows: [], problems: [Problem.new(nil, message)],
                 existing_count: 0, unmatched: [], notes: {})
    end
  end
end
