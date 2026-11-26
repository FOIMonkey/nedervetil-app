# == Schema Information
#
# Table name: authority_feed_items
#
#  id                       :bigint           not null, primary key
#  authority_feed_id        :bigint           not null
#  public_body_id           :bigint
#  authority_name           :string
#  occurred_on              :date             not null
#  reference                :string
#  title                    :text
#  outcome                  :string
#  url                      :text
#  dedupe_key               :string           not null
#  authority_feed_import_id :bigint
#  hidden_at                :datetime
#  created_at               :datetime         not null
#  updated_at               :datetime         not null
#

module AuthorityFeeds
  # public_body_id is nil until the source's name for the authority is matched.
  class Item < ApplicationRecord
    self.table_name = 'authority_feed_items'

    belongs_to :feed, class_name: 'AuthorityFeeds::Feed',
                      foreign_key: :authority_feed_id,
                      inverse_of: :items
    belongs_to :public_body, optional: true
    belongs_to :import, class_name: 'AuthorityFeeds::Import',
                        foreign_key: :authority_feed_import_id,
                        optional: true,
                        inverse_of: :items

    scope :visible, -> { where(hidden_at: nil) }
    scope :newest_first, -> { order(occurred_on: :desc, id: :desc) }
  end
end
