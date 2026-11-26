# == Schema Information
#
# Table name: authority_feed_figures
#
#  id                :bigint           not null, primary key
#  authority_feed_id :bigint           not null
#  public_body_id    :bigint
#  scope_key         :string           not null
#  period            :string           not null
#  metric            :string           not null
#  value             :decimal(16, 2)   not null
#  created_at        :datetime         not null
#  updated_at        :datetime         not null
#

module AuthorityFeeds
  # One figure from a feed: an authority's or a sector's value for a metric
  # in a period.
  class Figure < ApplicationRecord
    self.table_name = 'authority_feed_figures'

    belongs_to :feed, class_name: 'AuthorityFeeds::Feed',
                      foreign_key: :authority_feed_id,
                      inverse_of: :figures
    belongs_to :public_body, optional: true

    def self.scope_key_for(body_id: nil, sector: nil)
      if body_id
        "body:#{body_id}"
      else
        "sector:#{sector}"
      end
    end

    def self.table(feed, body_id: nil, sector: nil)
      where(authority_feed_id: feed.id,
            scope_key: scope_key_for(body_id: body_id, sector: sector)).
        pluck(:period, :metric, :value).
        each_with_object({}) do |(period, metric, value), table|
          (table[period] ||= {})[metric] = value.to_i
        end
    end
  end
end
