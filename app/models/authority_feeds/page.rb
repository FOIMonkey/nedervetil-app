module AuthorityFeeds
  # The data sections of one authority's page.
  class Page
    TILES = 3
    Tab = Struct.new(:key, :label, keyword_init: true)
    Tile = Struct.new(:value, :format, :label, :extra, :tab, :feed_key,
                      keyword_init: true)

    attr_reader :body

    def initialize(body, documents: false)
      @body = body
      @documents = documents
    end

    def feeds
      @feeds ||= Feed.visible.ordered.to_a.select { |feed| feed.for?(body) }
    end

    def summaries
      @summaries ||= Summary.where(public_body_id: body.id,
                                   authority_feed_id: feeds.map(&:id)).
                     index_by(&:authority_feed_id)
    end

    def summary(feed)
      feed && summaries[feed.id]
    end

    def shown?(feed)
      summary(feed)&.items_count.to_i.positive?
    end

    def feed(key)
      feeds.find { |feed| feed.key == key }
    end

    def feeds_on(tab, kind: nil)
      feeds.select do |feed|
        feed.tab == tab && (kind.nil? || feed.kind == kind) && shown?(feed)
      end
    end

    def releases
      AuthorityGroups::ExternalRelease.visible.where(public_body_id: body.id)
    end

    def releases?
      return @releases if defined?(@releases)

      @releases = releases.exists?
    end

    def tabs
      @tabs ||= begin
        list = []
        if @documents || releases?
          list << Tab.new(key: 'documents', label: _('Documents'))
        end
        if decision_feeds.any? || foi_record
          list << Tab.new(key: 'foi_record', label: _('FOI record'))
        end
        if list.empty?
          []
        else
          [Tab.new(key: 'overview', label: _('Overview'))] + list
        end
      end
    end

    def tab?(key)
      tabs.any? { |tab| tab.key == key }
    end

    def foi_record
      return @foi_record if defined?(@foi_record)

      statistics = feed(FoiStatistics::FEED)
      @foi_record =
        if statistics && shown?(statistics)
          FoiStatistics.record_for(statistics, summary(statistics))
        end
    end

    def spotlights
      @spotlights ||= feeds.select { |feed| shown?(feed) }.
                      flat_map { |feed| tiles(feed) }.first(TILES)
    end

    # Avoids repeating FOI figures in the sidebar when already spotlighted.
    def record_at_top?
      spotlights.any? { |tile| tile.feed_key == FoiStatistics::FEED }
    end

    def decision_feeds
      feeds_on('foi_record', kind: 'decisions')
    end

    def decisions(limit: nil)
      scope = Item.visible.
              where(public_body_id: body.id,
                    authority_feed_id: decision_feeds.map(&:id)).
              newest_first.includes(:feed)
      limit ? scope.limit(limit) : scope
    end

    def decisions_count
      decision_feeds.sum { |feed| summary(feed).items_count }
    end

    def decisions_latest_on
      decision_feeds.filter_map { |feed| summary(feed).latest_on }.max
    end

    def holdings
      @holdings ||= Holdings.new(body)
    end

    def notes
      @notes ||= Notes.new(body)
    end

    def links
      @links ||= Link.ordered.filter_map do |link|
        (url = link.url_for(body)) && [link.label, url]
      end
    end

    # A group's page uses these too (AuthorityGroups::Page).
    def self.record_tiles(feed, record)
      return [] unless record&.current

      year = record.year.tr('-', '–')
      Array(feed.spotlights).filter_map do |metric|
        case metric
        when 'on_time'
          record.on_time &&
            Tile.new(value: record.on_time,
                     format: :percent,
                     label: _('Answered on time, {{year}}', year: year),
                     tab: feed.tab,
                     feed_key: feed.key)
        when 'requests'
          Tile.new(value: record.requests,
                   format: :number,
                   label: _('Requests, {{year}}', year: year),
                   tab: feed.tab,
                   feed_key: feed.key)
        when 'released'
          record.released &&
            Tile.new(value: record.released,
                     format: :percent,
                     label: _('Got some or all, {{year}}', year: year),
                     tab: feed.tab,
                     feed_key: feed.key)
        end
      end
    end

    private

    def tiles(feed)
      case feed.kind
      when 'figures' then figure_tiles(feed)
      when 'decisions' then decision_tiles(feed)
      else []
      end
    end

    def figure_tiles(feed)
      if feed.key == FoiStatistics::FEED
        self.class.record_tiles(feed, foi_record)
      else
        []
      end
    end

    def decision_tiles(feed)
      unless Array(feed.spotlights).include?('count') && feed.up_to_date?
        return []
      end

      first = summary(feed).first_on
      [Tile.new(value: summary(feed).items_count,
                format: :number,
                label: feed.heading,
                extra: first && _('Since {{year}}', year: first.year),
                tab: feed.tab,
                feed_key: feed.key)]
    end
  end
end
