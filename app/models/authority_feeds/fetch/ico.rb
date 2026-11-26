module AuthorityFeeds
  module Fetch
    # New ICO decision notices, from the search behind ico.org.uk's decision
    # notices page. The ICO gives an outcome per section.
    class Ico
      URL = 'https://ico.org.uk/api/search'.freeze
      BASE = 'https://ico.org.uk'.freeze
      ROOT_PAGE_ID = 13_635
      MAX_PAGES = 20

      def initialize(http: Http.new)
        @http = http
      end

      def notices(since:)
        (1..MAX_PAGES).each_with_object([]) do |page, found|
          data = JSON.parse(@http.post_json(URL, query(page, since)))
          found.concat(
            Array(data['results']).filter_map { |result| notice(result) }
          )
          break found unless data.dig('pagination', 'hasMore')
        end
      end

      def self.outcome(decisions)
        statuses = Array(decisions).filter_map do |decision|
          decision['status'].to_s.squish.downcase.presence
        end.uniq
        if statuses.empty? then nil
        elsif statuses == ['upheld'] then 'Upheld'
        elsif statuses == ['not upheld'] then 'Not upheld'
        else 'Partly upheld'
        end
      end

      # "The complainant requested information from X (the “Council”) regarding
      # Y." becomes "Y".
      def self.title(description)
        text = description.to_s.squish.split(/(?<=\.)\s/).first.to_s.
               delete_suffix('.')
        # rubocop:disable Layout/LineLength
        text = text.sub(/\AThe complainants? (?:has |have )?(?:requested|asked for|asked|made a request for|submitted a request for)\s+/i, '')
        text = text.sub(/\AThe complainants? (?:has |have )?(?:submitted|made) an? (?:freedom of )?(?:information )?request (?:to .+? )?(?:for|about|regarding|concerning|relating to|in relation to|asking for)\s+/i, '')
        text = text.sub(/\A(?:from\s+.+?\s+)?information\s+(?:from\s+.+?\s+)?(?:about|on|regarding|relating to|concerning|in relation to|in respect of)\s+/i, '')
        # rubocop:enable Layout/LineLength
        text = text.gsub(
          /\s*\((?:the\s+)?[“"][^)]*[”"]\)|\s*\(the\s+\p{Lu}[^)]{0,40}\)/, ''
        ).squish
        text = text.sub(/\A\p{Ll}/, &:upcase)
        text.presence&.truncate(TITLE_MAX)
      end

      private

      def query(page, since)
        { filters: [{ key: 'date_range', values: ['true'] },
                    { key: 'from', values: [since.iso8601] }],
          pageNumber: page,
          order: 'newest',
          rootPageId: ROOT_PAGE_ID }
      end

      def notice(result)
        path = result['url'].to_s
        reference = path.delete_suffix('/').split('/').last.to_s.upcase
        decided_on =
          begin
            Date.strptime(
              result['filterItemMetaData'].to_s.split(',').first.to_s.strip,
              '%d %B %Y'
            )
          rescue Date::Error
            nil
          end
        return nil if reference.empty? || decided_on.nil?

        { authority_name: result['title'],
          decided_on: decided_on,
          reference: reference,
          title: self.class.title(result['description']),
          outcome: self.class.outcome(result['filterItemDecisions']),
          url: AuthorityGroups::ExternalRelease.
            normalise_url(URI.join(BASE, path).to_s) }
      end
    end
  end
end
