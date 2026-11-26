module AuthorityFeeds
  # A history of regulators' decisions, uploaded once before the daily fetch
  # takes over. Rows whose name matches no authority are kept and matched
  # later.
  class DecisionsCsv < Reading
    COLUMNS = {
      body: %w[body url_name],
      gss_code: %w[gss_code],
      authority: %w[authority authority_name],
      date: %w[date decision_date date_issued],
      reference: %w[reference ref id],
      title: %w[title description],
      outcome: %w[outcome],
      url: %w[url link source_url]
    }.freeze

    def initialize(text, feed)
      super(text)
      @feed = feed
    end

    private

    def required
      %i[date reference]
    end

    def build(records)
      matcher = Matcher.new(@feed)
      by_url_name = PublicBody::Translation.
                    where(url_name: records.filter_map { |r| r[:body] }.uniq).
                    pluck(:url_name, :public_body_id).to_h
      problems = []
      rows = {}
      records.each.with_index(2) do |record, line|
        decided_on = date(record[:date])
        if decided_on.nil?
          problems << Problem.new(line, 'No date, or not one this can read ' \
                                        '(use YYYY-MM-DD).')
          next
        end
        body_id = (record[:body] && by_url_name[record[:body]]) ||
                  matcher.find(record[:authority])
        row = Decisions.row(feed: @feed,
                            public_body_id: body_id,
                            authority_name: record[:authority],
                            decided_on: decided_on,
                            reference: record[:reference],
                            title: record[:title],
                            outcome: record[:outcome],
                            url: url(record[:url]))
        if rows[row[:dedupe_key]]
          problems << Problem.new(
            line,
            "Same reference as line #{rows[row[:dedupe_key]][:line]}; " \
            'this line is used.'
          )
        end
        rows[row[:dedupe_key]] = row.merge(line: line)
      end
      rows = rows.values.map { |row| row.except(:line) }
      Result.new(
        rows: rows,
        problems: problems,
        existing_count: existing_count(rows.map { |row| row[:dedupe_key] }),
        unmatched: unmatched_names(rows),
        notes: {}
      )
    end

    def unmatched_names(rows)
      rows.select { |row| row[:public_body_id].nil? }.
        filter_map { |row| row[:authority_name] }.tally.
        sort_by { |name, n| [-n, name] }
    end

    def existing_count(keys)
      keys.uniq.each_slice(BATCH).sum do |slice|
        Item.where(authority_feed_id: @feed.id, dedupe_key: slice).count
      end
    end
  end
end
