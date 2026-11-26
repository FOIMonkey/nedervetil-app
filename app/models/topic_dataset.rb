# Admin-editable dataset backing Topics::Dataset; `key` is immutable because
# TopicQuestion and TopicGuide reference it. See doc/FORK.md.
class TopicDataset < ApplicationRecord
  include TopicChange::Recorded

  validates :key, presence: true, uniqueness: true,
                  format: { with: Topics::Topic::SLUG, allow_blank: true }
  validate :key_kept, on: :update
  validates :publisher, :title, :url, presence: true
  validates :url, topic_url: true
  validates :kind, inclusion: { in: Topics::Dataset::KINDS }
  validates :status, inclusion: { in: Topics::Dataset::STATUSES }
  validates :nations, topic_nations: true
  validate :area_url_opens_an_area

  def self.datasets
    order(:id).map { |row| Topics::Dataset.new(row.data) }
  end

  def data
    TopicPage.as_file(
      attributes.except('id', 'key', 'table_title', 'created_at', 'updated_at').
        merge('id' => key, 'table' => table_title)
    )
  end

  private

  def key_kept
    errors.add(:key, 'can’t change once the dataset exists') if key_changed?
  end

  def area_url_opens_an_area
    return if area_url.blank?

    unless area_url.include?('{gss}') &&
           TopicUrlValidator.web_address?(area_url.sub('{gss}', 'gss'))
      errors.add(:area_url, 'must be a web address with {gss} where the ' \
                            'area’s code goes')
    end
    return if area_codes.any?

    errors.add(:area_codes, 'must list the area codes the address takes')
  end
end
