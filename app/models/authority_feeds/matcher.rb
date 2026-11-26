require 'csv'

module AuthorityFeeds
  # The authority a source means by its name: an admin's alias first, then,
  # for the Scottish Information Commissioner, the statistics crosswalk (which
  # knows the old names), then the authorities' own names and short names.
  class Matcher
    def self.normalise(name)
      name.to_s.downcase.gsub('&', ' and ').delete("’'").
        gsub(/[^a-z0-9]+/, ' ').squish.delete_prefix('the ')
    end

    def initialize(feed)
      @feed = feed
    end

    def find(name)
      key = self.class.normalise(name)
      return nil if key.empty?

      aliases[key] || crosswalk[key] || names[key]
    end

    private

    def aliases
      @aliases ||= @feed.aliases.pluck(:name, :public_body_id).to_h
    end

    def crosswalk
      @crosswalk ||=
        if @feed.key.start_with?('sic_') &&
           (file = ThemeData.file('foi_statistics/scotland-crosswalk.csv'))
          rows = CSV.read(file, headers: true).map do |row|
            [self.class.normalise(row['sic_name']), row['tag']]
          end
          ids = HasTagString::HasTagStringTag.
                where(model_type: 'PublicBody', name: 'sic',
                      value: rows.map(&:last).uniq).
                pluck(:value, :model_id).to_h
          rows.filter_map { |name, tag| [name, ids[tag]] if ids[tag] }.to_h
        else
          {}
        end
    end

    # A short name two authorities share matches neither.
    def names
      @names ||= begin
        rows = PublicBody::Translation.
               where(locale: AlaveteliLocalization.default_locale).
               pluck(:name, :short_name, :public_body_id)
        named = rows.filter_map do |_, name, id|
          [self.class.normalise(name), id] if name.present?
        end
        short = named.group_by(&:first).filter_map do |name, pairs|
          [name, pairs.first.last] if pairs.map(&:last).uniq.one?
        end.to_h
        short.merge(
          rows.to_h { |name, _, id| [self.class.normalise(name), id] }
        )
      end
    end
  end
end
