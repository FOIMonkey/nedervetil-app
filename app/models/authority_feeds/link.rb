# == Schema Information
#
# Table name: authority_links
#
#  id           :bigint           not null, primary key
#  label        :string           not null
#  url_template :string           not null
#  tag          :string
#  position     :integer          default(0), not null
#  created_at   :datetime         not null
#  updated_at   :datetime         not null
#

module AuthorityFeeds
  # An address that is only {value} takes the tag's value as the whole address
  # (spending:https://…).
  class Link < ApplicationRecord
    self.table_name = 'authority_links'

    scope :ordered, -> { order(:position, :id) }

    before_validation { self.tag = tag.to_s.strip.delete_suffix(':').presence }

    validates :label, presence: true, length: { maximum: 40 }
    validates :url_template,
              presence: true,
              format: {
                with: %r{\A(https?://.*|/(?![/\\]).*|\{value\})\z},
                message: 'must start with https:// or /, or be {value}'
              }
    validates :tag, format: { with: /\A[a-z0-9_]+\z/ }, allow_nil: true
    validate :value_needs_tag

    def url_for(body)
      value = tag &&
              body.tags.find { |t| t.name == tag && t.value.present? }&.value
      return nil if tag && value.nil?
      if url_template == '{value}'
        return AuthorityGroups::ExternalRelease.normalise_url(value)
      end

      url_template.gsub('{value}') { ERB::Util.url_encode(value.to_s) }.
        gsub('{url_name}') { ERB::Util.url_encode(body.url_name.to_s) }
    end

    private

    def value_needs_tag
      errors.add(:url_template, 'uses {value}, so it needs a tag') if
        url_template.to_s.include?('{value}') && tag.nil?
    end
  end
end
