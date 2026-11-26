require 'csv'

module AuthorityFeeds
  # Reads an uploaded CSV file. Each reader defines COLUMNS ({ key => [header
  # names] }), required (keys) and build(records).
  class Reading
    MAX_ROWS = 20_000
    # Bounds what one row can cost: a real row is a few short fields.
    LINE_MAX = 20_000

    def initialize(text)
      @text = text.to_s
    end

    def result
      @result ||= read
    end

    private

    # Streams rows keeping only known columns to bound memory on wide CSVs.
    def read
      if @text.each_line.any? { |line| line.length > LINE_MAX }
        return failed("A line is longer than #{LINE_MAX} characters.")
      end

      csv = CSV.new(
        @text,
        headers: true,
        header_converters: ->(name) { name.to_s.strip.downcase.tr(' ', '_') }
      )
      columns = nil
      records = []
      csv.each do |record|
        unless columns
          columns = columns_for(csv.headers)
          return missing(columns) if missing_columns(columns).any?
        end
        if records.size == MAX_ROWS
          return failed("More than #{MAX_ROWS} rows. Split the file.")
        end

        records << columns.transform_values do |name|
          name && record[name].to_s.strip.presence
        end
      end
      columns ||= columns_for(csv.headers.is_a?(Array) ? csv.headers : [])
      missing_columns(columns).any? ? missing(columns) : build(records)
    rescue CSV::MalformedCSVError => e
      failed("Not a readable CSV file (#{e.message}).")
    end

    def columns_for(headers)
      self.class::COLUMNS.transform_values do |names|
        names.find { |name| headers.include?(name) }
      end
    end

    def missing(columns)
      failed("Missing columns: #{missing_columns(columns).join(', ')}.")
    end

    def missing_columns(columns)
      missing = required.reject { |key| columns[key] }.map(&:to_s)
      unless columns.values_at(:body, :gss_code, :authority).any?
        missing.unshift('body, gss_code or authority')
      end
      missing
    end

    def failed(message)
      Result.new(rows: [], problems: [Problem.new(nil, message)],
                 existing_count: 0, unmatched: [], notes: {})
    end

    def date(text)
      return nil unless text

      day_first = text.match(%r{\A(\d{1,2})/(\d{1,2})/(\d{4})\z})
      date = if text.match?(/\A\d{4}-\d{2}-\d{2}/)
               Date.iso8601(text[0, 10])
             elsif day_first
               Date.new(day_first[3].to_i, day_first[2].to_i, day_first[1].to_i)
             end
      date if date && date.year >= 1990 && date <= Date.current + 1
    rescue Date::Error
      nil
    end

    def url(text)
      AuthorityGroups::ExternalRelease.normalise_url(text)
    end
  end
end
