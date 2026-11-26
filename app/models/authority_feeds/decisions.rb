module AuthorityFeeds
  # Regulators' decisions: their outcomes and titles, the rows saved for
  # them, and matching unmatched names again.
  module Decisions
    OUTCOMES = {
      'for applicant' => 'Upheld',
      'upheld' => 'Upheld',
      'complaint upheld' => 'Upheld',
      'partially upheld' => 'Partly upheld',
      'partly upheld' => 'Partly upheld',
      'complaint partly upheld' => 'Partly upheld',
      'for authority' => 'Not upheld',
      'not upheld' => 'Not upheld',
      'complaint not upheld' => 'Not upheld'
    }.freeze
    WORD = /\p{L}{3}/

    module_function

    def outcome(text)
      key = text.to_s.squish.downcase
      OUTCOMES.fetch(key) { text.to_s.squish.presence }
    end

    def row(feed:, public_body_id:, authority_name:, decided_on:, reference:, title:, outcome:, url:)
      reference = reference.to_s.squish
      { public_body_id: public_body_id,
        authority_name: authority_name.to_s.squish.first(255).presence,
        occurred_on: decided_on,
        reference: reference.first(255),
        title: title(title),
        outcome: outcome(outcome),
        url: url,
        dedupe_key: "#{feed.key}:#{reference.downcase}" }
    end

    # No title unless it has a word (the source's own rows include "1"), so
    # pages show the reference.
    def title(text)
      text.to_s.squish.truncate(TITLE_MAX).presence&.then do |title|
        title if title.match?(WORD)
      end
    end

    def rematch(feed)
      matcher = Matcher.new(feed)
      ids = []
      Item.where(authority_feed_id: feed.id, public_body_id: nil).distinct.
        pluck(:authority_name).each do |name|
          id = matcher.find(name) or next
          Item.where(authority_feed_id: feed.id, public_body_id: nil,
                     authority_name: name).
            update_all(public_body_id: id, updated_at: Time.current)
          ids << id
        end
      Summaries.rebuild(feed, ids)
      ids.uniq.size
    end
  end
end
