# == Schema Information
#
# Table name: authority_feeds
#
#  id          :bigint           not null, primary key
#  key         :string           not null
#  heading     :string           not null
#  tab         :string           not null
#  kind        :string           not null
#  position    :integer          default(0), not null
#  updates     :string           default("weekly"), not null
#  source_line :string
#  licence     :string
#  only_tags   :string
#  spotlights  :jsonb            not null
#  checked_at  :datetime
#  check_error :string
#  hidden_at   :datetime
#  created_at  :datetime         not null
#  updated_at  :datetime         not null
#

module AuthorityFeeds
  # A source of data for authority pages, such as a regulator's decisions.
  class Feed < ApplicationRecord
    self.table_name = 'authority_feeds'

    TABS = { 'overview' => 'Overview',
             'documents' => 'Documents',
             'foi_record' => 'FOI record' }.freeze
    KINDS = { 'decisions' => 'List', 'figures' => 'Figures' }.freeze
    # A source is late when its last check is older than this.
    UPDATES = { 'daily' => 2.days,
                'weekly' => 9.days,
                'monthly' => 40.days,
                'quarterly' => 100.days,
                'yearly' => 400.days }.freeze
    # What each kind can show at the top of the Overview.
    SPOTLIGHTS = {
      'figures' => { 'on_time' => 'Answered on time',
                     'requests' => 'Requests',
                     'released' => 'Got some or all of the information' },
      'decisions' => { 'count' => 'Number of decisions' }
    }.freeze
    FETCHED = %w[sic_decisions ico_decisions].freeze
    STATUSES = { late: 'Late',
                 not_started: 'Not started',
                 up_to_date: 'Up to date' }.freeze

    has_many :items, class_name: 'AuthorityFeeds::Item',
                     foreign_key: :authority_feed_id,
                     inverse_of: :feed,
                     dependent: :delete_all
    has_many :figures, class_name: 'AuthorityFeeds::Figure',
                       foreign_key: :authority_feed_id,
                       inverse_of: :feed,
                       dependent: :delete_all
    has_many :summaries, class_name: 'AuthorityFeeds::Summary',
                         foreign_key: :authority_feed_id,
                         inverse_of: :feed,
                         dependent: :delete_all
    has_many :imports, class_name: 'AuthorityFeeds::Import',
                       foreign_key: :authority_feed_id,
                       inverse_of: :feed,
                       dependent: :destroy
    has_many :aliases, class_name: 'AuthorityFeeds::NameAlias',
                       foreign_key: :authority_feed_id,
                       inverse_of: :feed,
                       dependent: :delete_all

    scope :visible, -> { where(hidden_at: nil) }
    scope :ordered, -> { order(:position, :id) }

    before_validation do
      self.only_tags = only_tags.to_s.split.uniq.join(' ').presence
    end

    validates :heading, presence: true, length: { maximum: 60 }
    validates :tab, inclusion: { in: TABS.keys }
    validates :kind, inclusion: { in: KINDS.keys }
    validates :updates, inclusion: { in: UPDATES.keys }
    validate :known_spotlights
    validate :tags_look_like_tags

    def tags
      only_tags.to_s.split
    end

    def for?(body)
      tags.all? { |tag| body.has_tag?(tag) }
    end

    def fetched?
      FETCHED.include?(key)
    end

    def hidden?
      hidden_at.present?
    end

    def tab_label
      TABS.fetch(tab)
    end

    def kind_label
      KINDS.fetch(kind)
    end

    def spotlight_choices
      SPOTLIGHTS.fetch(kind)
    end

    def state
      if check_error.present? ||
         (checked_at && checked_at < UPDATES.fetch(updates).ago)
        :late
      elsif checked_at.nil?
        :not_started
      else
        :up_to_date
      end
    end

    def status
      STATUSES.fetch(state)
    end

    def late?
      state == :late
    end

    def up_to_date?
      state == :up_to_date
    end

    private

    def known_spotlights
      unknown = Array(spotlights) - spotlight_choices.keys
      errors.add(:spotlights, "can’t include #{unknown.join(', ')}") if
        kind.in?(KINDS.keys) && unknown.any?
    end

    def tags_look_like_tags
      bad = tags.reject { |tag| tag.match?(/\A[a-z0-9_]+\z/) }
      errors.add(:only_tags, "aren’t tag names: #{bad.join(' ')}") if bad.any?
    end
  end
end
