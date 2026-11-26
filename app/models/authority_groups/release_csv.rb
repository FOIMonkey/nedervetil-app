module AuthorityGroups
  # Column names follow foi-aggregator's.
  class ReleaseCsv < AuthorityFeeds::Reading
    COLUMNS = {
      body: %w[body url_name], gss_code: %w[gss_code gss],
      authority: %w[authority authority_name], title: %w[title],
      url: %w[url link], published_date: %w[released_on published_date date],
      received_date: %w[received_date], log_url: %w[log_url]
    }.freeze

    Row = Struct.new(:line, :public_body_id, :title, :url, :url_key,
                     :released_on, :log_url, keyword_init: true)

    private

    def required
      %i[title url published_date]
    end

    def build(records)
      bodies = BodyFinder.new(records)
      problems = []
      rows = {}
      records.each.with_index(2) do |record, line|
        row = row_for(record, line, bodies, problems) or next
        key = [row.public_body_id, row.url_key]
        if rows[key]
          message = "Same link as line #{rows[key].line}; this line is used."
          problems << AuthorityFeeds::Problem.new(line, message)
        end
        rows[key] = row
      end
      AuthorityFeeds::Result.new(rows: rows.values, problems: problems,
                                 existing_count: existing_count(rows.keys),
                                 unmatched: [], notes: {})
    end

    def row_for(record, line, bodies, problems)
      body_id = bodies.find(record[:body], record[:gss_code],
                            record[:authority])
      title = record[:title]&.squish&.truncate(AuthorityFeeds::TITLE_MAX)
      url = ExternalRelease.normalise_url(record[:url])
      released_on = date(record[:published_date]) ||
                    date(record[:received_date])
      problem =
        if body_id.nil?
          'No authority matches.'
        elsif title.nil?
          'No title.'
        elsif url.nil?
          'The link must be a web address starting http:// or https://.'
        elsif released_on.nil?
          'No date, or not one this can read (use YYYY-MM-DD).'
        end
      if problem
        problems << AuthorityFeeds::Problem.new(line, problem)
        return nil
      end

      Row.new(line: line,
              public_body_id: body_id,
              title: title,
              url: url,
              url_key: ExternalRelease.url_key(url),
              released_on: released_on,
              log_url: ExternalRelease.normalise_url(record[:log_url]))
    end

    def existing_count(keys)
      keys.each_slice(AuthorityFeeds::BATCH).sum do |slice|
        wanted = slice.to_set
        ExternalRelease.where(public_body_id: slice.map(&:first).uniq,
                              url_key: slice.map(&:last)).
          pluck(:public_body_id, :url_key).
          count { |pair| wanted.include?(pair) }
      end
    end

    # One query per way of naming an authority, whatever the number of rows.
    class BodyFinder
      def initialize(records)
        values = ->(key) { records.filter_map { |record| record[key] }.uniq }
        @by_url_name = PublicBody::Translation.
                       where(url_name: values[:body]).
                       pluck(:url_name, :public_body_id).to_h
        @by_gss = HasTagString::HasTagStringTag.
                  where(model_type: 'PublicBody', name: 'gss',
                        value: values[:gss_code]).
                  pluck(:value, :model_id).to_h
        names = values[:authority].map(&:downcase)
        @by_name = if names.empty?
                     {}
                   else
                     PublicBody::Translation.
                       where('lower(name) IN (?)', names).
                       pluck(Arel.sql('lower(name)'), :public_body_id).to_h
                   end
      end

      def find(url_name, gss_code, name)
        (url_name && @by_url_name[url_name]) ||
          (gss_code && @by_gss[gss_code]) ||
          (name && @by_name[name.downcase])
      end
    end
  end
end
