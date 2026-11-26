# == Schema Information
#
# Table name: authority_feed_aliases
#
#  id                :bigint           not null, primary key
#  authority_feed_id :bigint           not null
#  name              :string           not null
#  public_body_id    :bigint           not null
#  created_at        :datetime         not null
#  updated_at        :datetime         not null
#

module AuthorityFeeds
  # An admin's match of a name a feed's source uses to an authority.
  class NameAlias < ApplicationRecord
    self.table_name = 'authority_feed_aliases'

    belongs_to :feed, class_name: 'AuthorityFeeds::Feed',
                      foreign_key: :authority_feed_id,
                      inverse_of: :aliases
    belongs_to :public_body

    before_validation { self.name = Matcher.normalise(name) }
    validates :name, presence: true, uniqueness: { scope: :authority_feed_id }
  end
end
