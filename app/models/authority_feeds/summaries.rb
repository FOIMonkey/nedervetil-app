module AuthorityFeeds
  # Rewrites one feed's summaries for some authorities from its rows or
  # figures, so pages never count or add up anything themselves.
  module Summaries
    module_function

    def rebuild(feed, body_ids)
      ids = body_ids.compact.uniq
      return if ids.empty?

      rows = feed.kind == 'figures' ? figures(feed, ids) : decisions(feed, ids)
      now = Time.current
      Summary.where(
        authority_feed_id: feed.id,
        public_body_id: ids - rows.map { |row| row[:public_body_id] }
      ).delete_all
      return if rows.empty?

      Summary.upsert_all(
        rows.map do |row|
          row.merge(authority_feed_id: feed.id,
                    created_at: now,
                    updated_at: now)
        end,
        unique_by: :index_authority_feed_summaries_unique,
        record_timestamps: false,
        update_only: %i[items_count latest_on latest_period periods updated_at]
      )
    end

    def decisions(feed, ids)
      Item.visible.where(authority_feed_id: feed.id, public_body_id: ids).
        group(:public_body_id).
        pluck(:public_body_id, Arel.sql('COUNT(*)'),
              Arel.sql('MAX(occurred_on)'), Arel.sql('MIN(occurred_on)')).
        map do |id, count, latest, first|
          { public_body_id: id,
            items_count: count,
            latest_on: latest,
            latest_period: nil,
            periods: { 'first_on' => first.iso8601 } }
        end
    end

    # The latest period's figures; the whole table is read only on the FOI
    # record tab.
    def figures(feed, ids)
      Figure.where(authority_feed_id: feed.id, public_body_id: ids).
        pluck(:public_body_id, :period, :metric, :value).
        group_by(&:first).map do |id, rows|
          periods = rows.map { |row| row[1] }.uniq
          latest = periods.max
          values = rows.select { |row| row[1] == latest }.
                   to_h { |_, _, metric, value| [metric, value.to_i] }
          { public_body_id: id,
            items_count: periods.size,
            latest_on: nil,
            latest_period: latest,
            periods: { latest => values } }
        end
    end
  end
end
