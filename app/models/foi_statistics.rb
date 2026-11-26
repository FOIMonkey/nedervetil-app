# FOI figures that Scottish authorities report to the Scottish Information
# Commissioner, shown on their authority pages. Percentages are worked out as
# the Commissioner's dashboard does.
module FoiStatistics
  FEED = 'sic_statistics'.freeze
  SOURCE = 'https://www.foi.scot/statistics'.freeze
  # Below this, one late reply moves the percentages too far to mean much.
  MIN_REQUESTS = 20
  # As the Commissioner's dashboard counts disclosure: refusals and
  # neither-confirm-nor-deny are left out.
  OUTCOMES = %w[full some none not_held].freeze

  Record = Struct.new(:year, :requests, :on_time, :released, :note, :source,
                      :current, keyword_init: true)

  module_function

  def feed
    AuthorityFeeds::Feed.visible.find_by(key: FEED)
  end

  def for_body(body)
    statistics = feed or return nil
    record_for(statistics,
               AuthorityFeeds::Summary.find_by(authority_feed_id: statistics.id,
                                               public_body_id: body.id))
  end

  def record_for(statistics, summary)
    return nil unless summary&.latest_period

    year = summary.latest_period
    record(
      year,
      summary.period(year),
      note: summary.note,
      current: AuthorityFeeds::Freshness.current?(year, statistics.updates)
    )
  end

  def years_for(statistics, body)
    own = AuthorityFeeds::Figure.table(statistics, body_id: body.id)
    all = AuthorityFeeds::Figure.table(statistics, sector: 'scotland')
    own.keys.sort.filter_map do |year|
      mine = record(year, own[year]) or next
      [year, mine, all[year] && record(year, all[year], minimum: 0)]
    end
  end

  def record(year, figures, note: nil, current: false, minimum: MIN_REQUESTS)
    return nil unless figures['requests'].to_i >= minimum

    Record.new(year: year,
               requests: figures['requests'].to_i,
               on_time: on_time(figures),
               released: released(figures),
               note: note,
               source: SOURCE,
               current: current)
  end

  def on_time(figures)
    share(
      figures['on_time'].to_i,
      %w[on_time late no_reply].sum { |key| figures[key].to_i }
    )
  end

  def released(figures)
    share(
      figures['full'].to_i + figures['some'].to_i,
      OUTCOMES.sum { |key| figures[key].to_i }
    )
  end

  def share(part, whole)
    whole.positive? ? (100.0 * part / whole).round : nil
  end
end
