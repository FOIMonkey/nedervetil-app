module AuthorityGroups
  # Answers the same calls as AuthorityFeeds::Page, so the authority pages'
  # partials render it. A fixed number of queries, however many members.
  class Page
    Tab = AuthorityFeeds::Page::Tab
    Summary = Struct.new(:items_count, :latest_on, keyword_init: true)

    attr_reader :group

    def initialize(group)
      @group = group
    end

    def ids
      group.body_ids
    end

    def nation
      defined?(Topics::Topic) && Topics::Topic::NATIONS.key?(group.tag) ? group.tag : nil
    end

    def feeds
      @feeds ||= AuthorityFeeds::Feed.visible.ordered.to_a
    end

    # Batch-computes { feed_id => Set of matching body_ids } (like Feed#for?).
    def members_for
      @members_for ||= begin
        tagged = feeds.flat_map(&:tags).uniq
        held =
          if tagged.empty?
            {}
          else
            HasTagString::HasTagStringTag.
              where(model_type: 'PublicBody', model_id: ids, name: tagged).
              distinct.pluck(:model_id, :name).group_by(&:first).
              transform_values { |pairs| pairs.map(&:last) }
          end
        feeds.to_h do |feed|
          members =
            if feed.tags.empty?
              ids
            else
              held.select { |_, names| (feed.tags - names).empty? }.keys
            end
          [feed.id, members.to_set]
        end
      end
    end

    def summaries
      @summaries ||=
        AuthorityFeeds::Summary.
        where(public_body_id: ids, authority_feed_id: feeds.map(&:id)).to_a.
        select do |row|
          members_for[row.authority_feed_id].include?(row.public_body_id)
        end.group_by(&:authority_feed_id)
    end

    def summary(feed)
      rows = summaries[feed.id] or return nil
      Summary.new(items_count: rows.sum(&:items_count),
                  latest_on: rows.filter_map(&:latest_on).max)
    end

    def decision_feeds
      feeds.select { |feed| feed.kind == 'decisions' && summaries[feed.id] }
    end

    def decisions(limit: nil)
      scope = decision_feeds.map do |feed|
        AuthorityFeeds::Item.where(authority_feed_id: feed.id,
                                   public_body_id: members_for[feed.id].to_a)
      end.reduce(:or) || AuthorityFeeds::Item.none
      scope = scope.visible.newest_first.
              includes(:feed, public_body: :translations)
      limit ? scope.limit(limit) : scope
    end

    def decisions_count
      decision_feeds.sum { |feed| summary(feed).items_count }
    end

    def decisions_latest_on
      decision_feeds.filter_map { |feed| summary(feed).latest_on }.max
    end

    def statistics
      feeds.find { |feed| feed.key == FoiStatistics::FEED }
    end

    def records
      @records ||= begin
        rows = (statistics && summaries[statistics.id]) || []
        year = rows.filter_map(&:latest_period).max
        rows.select { |row| row.latest_period == year }.
          filter_map do |row|
            (record = FoiStatistics.record(year, row.period(year))) &&
              [row.public_body_id, record]
          end.to_h
      end
    end

    # Aggregate figures, shown only when at least half of members report.
    def record
      return @record if defined?(@record)

      @record =
        if records.size * 2 >= ids.size && records.any?
          year = records.values.first.year
          totals =
            summaries[statistics.id].
            select { |row| row.latest_period == year }.
            each_with_object(Hash.new(0)) do |row, sum|
              row.period(year).each { |metric, value| sum[metric] += value }
            end
          FoiStatistics.record(
            year, totals,
            minimum: 0,
            current:
              AuthorityFeeds::Freshness.current?(year, statistics.updates)
          )
        end
    end

    def spotlights
      if record
        AuthorityFeeds::Page.record_tiles(statistics, record)
      else
        []
      end
    end

    def on_time_values
      records.values.filter_map(&:on_time)
    end

    def who_does_what
      @who_does_what ||= defined?(Topics::Holds) ? Topics::Holds.for_group(ids, nation) : []
    end

    def tabs(documents:)
      list = [Tab.new(key: 'overview', label: _('Overview')),
              Tab.new(key: 'authorities', label: _('Authorities'))]
      list << Tab.new(key: 'documents', label: _('Documents')) if documents
      if record || decision_feeds.any?
        list << Tab.new(key: 'foi_record', label: _('FOI record'))
      end
      list
    end
  end
end
