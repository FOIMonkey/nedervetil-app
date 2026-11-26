module AuthorityFeeds
  # Saving the same row again (same dedupe key) updates it; nothing is
  # deleted, and a row an admin has hidden stays hidden.
  class Store
    ITEM_FIELDS = %i[
      public_body_id authority_name occurred_on reference title outcome url
      dedupe_key
    ].freeze

    def initialize(feed, import: nil)
      @feed = feed
      @import = import
    end

    def save_items(rows)
      now = Time.current
      keys = rows.map { |row| row[:dedupe_key] }
      before = existing_items(keys)
      rows.each_slice(BATCH) do |slice|
        Item.upsert_all(
          slice.map do |row|
            row.slice(*ITEM_FIELDS).merge(authority_feed_id: @feed.id,
                                          authority_feed_import_id: @import&.id,
                                          created_at: now,
                                          updated_at: now)
          end,
          unique_by: %i[authority_feed_id dedupe_key],
          record_timestamps: false,
          update_only: ITEM_FIELDS - %i[dedupe_key] + %i[updated_at]
        )
      end
      Summaries.rebuild(@feed,
                        rows.map { |row| row[:public_body_id] } + before.values)
      { added: (keys.uniq - before.keys).size,
        updated: (keys.uniq & before.keys).size }
    end

    def save_figures(rows, notes: {})
      now = Time.current
      before = Figure.where(authority_feed_id: @feed.id,
                            scope_key: rows.map { |row| row[:scope_key] }.uniq).
               pluck(:scope_key, :period, :metric).to_set
      rows.each_slice(BATCH) do |slice|
        Figure.upsert_all(
          slice.map do |row|
            row.slice(:scope_key, :public_body_id, :period, :metric, :value).
              merge(authority_feed_id: @feed.id,
                    created_at: now,
                    updated_at: now)
          end,
          unique_by: :index_authority_feed_figures_unique,
          record_timestamps: false,
          update_only: %i[value updated_at]
        )
      end
      body_ids = rows.filter_map { |row| row[:public_body_id] }.uniq
      Summaries.rebuild(@feed, body_ids)
      Summary.where(authority_feed_id: @feed.id, public_body_id: body_ids).
        update_all(note: nil)
      notes.each do |id, note|
        Summary.where(authority_feed_id: @feed.id, public_body_id: id).
          update_all(note: note)
      end
      added = rows.count do |row|
        !before.include?(row.values_at(:scope_key, :period, :metric))
      end
      { added: added, updated: rows.size - added }
    end

    private

    # { dedupe key => authority id } for rows already saved, so moved rows' old
    # authorities are rebuilt too.
    def existing_items(keys)
      keys.uniq.each_slice(BATCH).each_with_object({}) do |slice, found|
        found.merge!(Item.where(authority_feed_id: @feed.id, dedupe_key: slice).
                     pluck(:dedupe_key, :public_body_id).to_h)
      end
    end
  end
end
