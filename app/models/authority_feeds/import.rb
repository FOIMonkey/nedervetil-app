# == Schema Information
#
# Table name: authority_feed_imports
#
#  id                :bigint           not null, primary key
#  authority_feed_id :bigint           not null
#  user_id           :bigint
#  filename          :string
#  state             :string           default("preview"), not null
#  body              :text
#  rows_count        :integer          default(0), not null
#  added_count       :integer          default(0), not null
#  updated_count     :integer          default(0), not null
#  skipped_count     :integer          default(0), not null
#  applied_at        :datetime
#  created_at        :datetime         not null
#  updated_at        :datetime         not null
#

module AuthorityFeeds
  # A decisions history is CSV; the Commissioner's statistics are JSON.
  class Import < ApplicationRecord
    include Upload

    self.table_name = 'authority_feed_imports'
    self.text_column = :body
    self.no_file_message = 'Choose a file.'
    self.encoding_message = 'Save the file as UTF-8 and try again.'

    READERS = { 'decisions' => 'AuthorityFeeds::DecisionsCsv',
                'figures' => 'AuthorityFeeds::StatisticsJson' }.freeze

    belongs_to :feed, class_name: 'AuthorityFeeds::Feed',
                      foreign_key: :authority_feed_id,
                      inverse_of: :imports
    belongs_to :user, optional: true
    has_many :items, class_name: 'AuthorityFeeds::Item',
                     foreign_key: :authority_feed_import_id,
                     inverse_of: :import,
                     dependent: :nullify

    private

    def reader
      READERS.fetch(feed.kind).constantize.new(body, feed)
    end

    def save_rows(result)
      store = Store.new(feed, import: self)
      counts = if feed.kind == 'figures'
                 store.save_figures(result.rows, notes: result.notes)
               else
                 store.save_items(result.rows)
               end
      feed.update!(checked_at: Time.current, check_error: nil)
      counts
    end
  end
end
