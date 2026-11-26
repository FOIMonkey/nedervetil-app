# == Schema Information
#
# Table name: authority_feed_summaries
#
#  id                :bigint           not null, primary key
#  authority_feed_id :bigint           not null
#  public_body_id    :bigint           not null
#  items_count       :integer          default(0), not null
#  latest_on         :date
#  latest_period     :string
#  periods           :jsonb            not null
#  note              :string
#  created_at        :datetime         not null
#  updated_at        :datetime         not null
#

module AuthorityFeeds
  # A feed's totals for one authority, written when its rows change.
  class Summary < ApplicationRecord
    self.table_name = 'authority_feed_summaries'

    belongs_to :feed, class_name: 'AuthorityFeeds::Feed',
                      foreign_key: :authority_feed_id,
                      inverse_of: :summaries
    belongs_to :public_body

    def period(name)
      periods.fetch(name.to_s, {})
    end

    # A list's oldest row (decisions keep it with their periods).
    def first_on
      periods['first_on'] && Date.iso8601(periods['first_on'])
    end
  end
end
