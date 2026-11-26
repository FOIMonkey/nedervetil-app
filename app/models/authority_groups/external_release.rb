# == Schema Information
#
# Table name: external_releases
#
#  id                         :bigint           not null, primary key
#  public_body_id             :bigint           not null
#  external_release_import_id :bigint
#  title                      :string           not null
#  url                        :text             not null
#  url_key                    :string           not null
#  released_on                :date             not null
#  log_url                    :text
#  hidden_at                  :datetime
#  pinned_at                  :datetime
#  edited_at                  :datetime
#  created_at                 :datetime         not null
#  updated_at                 :datetime         not null
#

require 'digest'

module AuthorityGroups
  # A release on an authority's own disclosure log: a title, date and link
  # out. Nothing is re-hosted.
  class ExternalRelease < ApplicationRecord
    self.table_name = 'external_releases'

    URL_MAX = 2_000

    belongs_to :public_body
    belongs_to :import, class_name: 'AuthorityGroups::ReleaseImport',
                        foreign_key: :external_release_import_id,
                        optional: true,
                        inverse_of: :releases

    scope :visible, -> { where(hidden_at: nil) }
    scope :pinned, -> { where.not(pinned_at: nil) }
    scope :unpinned, -> { where(pinned_at: nil) }
    scope :newest_first, -> { order(released_on: :desc, id: :desc) }

    before_validation :normalise

    validates :title, presence: true,
                      length: { maximum: AuthorityFeeds::TITLE_MAX }
    validates :released_on, presence: true
    validate :web_address
    validate :one_per_link,
             if: -> { url_key.present? && public_body_id.present? }

    def self.normalise_url(value)
      text = value.to_s.strip.gsub(' ', '%20')
      return nil if text.empty? || text.length > URL_MAX

      uri = URI.parse(text)
      return nil unless uri.is_a?(URI::HTTP) && uri.host.present?

      uri.scheme = uri.scheme.downcase
      uri.host = uri.host.downcase
      uri.fragment = nil
      uri.to_s
    rescue URI::InvalidURIError
      nil
    end

    def self.url_key(url)
      Digest::SHA256.hexdigest(url)
    end

    def hidden?
      hidden_at.present?
    end

    def pinned?
      pinned_at.present?
    end

    private

    def normalise
      self.title = title.to_s.squish.presence
      normalised = self.class.normalise_url(url)
      self.url = normalised if normalised
      self.url_key = normalised && self.class.url_key(normalised)
      self.log_url = self.class.normalise_url(log_url)
    end

    def web_address
      return if url_key

      errors.add(:url, 'must be a web address starting http:// or https://')
    end

    def one_per_link
      duplicate = self.class.where(public_body_id: public_body_id,
                                   url_key: url_key).
                  where.not(id: id).exists?
      errors.add(:url, 'is already listed for this authority') if duplicate
    end
  end
end
