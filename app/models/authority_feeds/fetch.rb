module AuthorityFeeds
  # Fetches regulator decision feeds from cron; failures are recorded on the
  # feed (shown as late in admin) and retried on the next run.
  module Fetch
    # Lookback before last check so late-indexed ICO notices aren't missed.
    OVERLAP = 7.days
    FIRST_RUN = 60.days

    module_function

    # Run from cron: bin/rails runner 'puts AuthorityFeeds::Fetch.run.to_json'.
    def run(http: Http.new)
      Feed.where(key: Feed::FETCHED).visible.ordered.to_a.
        to_h { |feed| [feed.key, run_one(feed, http)] }
    end

    def run_one(feed, http)
      notices =
        case feed.key
        when 'ico_decisions'
          Ico.new(http: http).notices(
            since: ((feed.checked_at || FIRST_RUN.ago) - OVERLAP).to_date
          )
        when 'sic_decisions'
          Sic.new(http: http, known: known(feed)).notices
        end
      matcher = Matcher.new(feed)
      rows = notices.map do |notice|
        Decisions.row(feed: feed,
                      public_body_id: matcher.find(notice[:authority_name]),
                      authority_name: notice[:authority_name],
                      decided_on: notice[:decided_on],
                      reference: notice[:reference],
                      title: notice[:title],
                      outcome: notice[:outcome],
                      url: notice[:url])
      end
      counts = Store.new(feed).save_items(rows.uniq { |row| row[:dedupe_key] })
      feed.update!(checked_at: Time.current, check_error: nil)
      counts
    rescue Http::Failed, JSON::ParserError => e
      feed.update!(check_error: e.message.first(250))
      { error: e.message }
    end

    def known(feed)
      ->(references) do
        keys = references.to_h do |reference|
          ["#{feed.key}:#{reference.to_s.squish.downcase}", reference]
        end
        Item.where(authority_feed_id: feed.id, dedupe_key: keys.keys).
          pluck(:dedupe_key).map { |key| keys[key] }
      end
    end
  end
end
