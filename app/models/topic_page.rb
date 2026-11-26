# Admin-editable topic page backing Topics::Topic; slug is immutable because
# URLs, TopicGuide, and TopicMatch reference it. See doc/FORK.md.
class TopicPage < ApplicationRecord
  include TopicChange::Recorded

  has_many :holders, -> { order(:position) },
           class_name: 'TopicHolder', inverse_of: :topic_page,
           dependent: :destroy
  has_many :questions, -> { order(:position) },
           class_name: 'TopicQuestion', inverse_of: :topic_page,
           dependent: :destroy
  has_many :sources, -> { order(:position) },
           class_name: 'TopicSource', inverse_of: :topic_page,
           dependent: :destroy
  has_many :routes, -> { order(:position) },
           class_name: 'TopicRoute', inverse_of: :topic_page,
           dependent: :destroy

  validates :slug, presence: true, uniqueness: true,
                   format: { with: Topics::Topic::SLUG, allow_blank: true }
  validate :slug_kept, on: :update
  validates :title, :summary, presence: true
  validates :position, numericality: { only_integer: true }
  validates :titles, topic_nations: { map: true }
  validate :documents_are_public_ids
  validate :refused_lines_written

  after_create :match_documents_later
  after_update :match_documents_later, if: :saved_change_to_search?
  after_destroy :match_documents_later

  def self.topics
    includes(:holders, :questions, :sources, :routes).order(:position, :slug).
      map { |page| Topics::Topic.new(page.slug, page.data) }
  end

  # Strips nil and empty arrays/hashes; preserves empty strings.
  def self.as_file(values)
    values.reject do |_, value|
      value.nil? || ((value.is_a?(Array) || value.is_a?(Hash)) && value.empty?)
    end
  end

  def to_param
    slug
  end

  def data
    self.class.as_file(
      'title' => title, 'titles' => titles, 'summary' => summary,
      'order' => position, 'search' => search,
      'elsewhere_heading' => elsewhere_heading, 'documents' => documents,
      'refused' => refused, 'holders' => holders.map(&:data),
      'questions' => questions.map(&:data),
      'published' => sources.map(&:data),
      'elsewhere' => routes.map(&:data)
    )
  end

  private

  def slug_kept
    errors.add(:slug, 'can’t change once the page exists') if slug_changed?
  end

  def documents_are_public_ids
    format = Disclosures::Document::PUBLIC_ID
    return if documents.all? { |id| id.match?(format) }

    errors.add(:documents, 'must be the public ids of documents')
  end

  def refused_lines_written
    errors.add(:refused, 'can’t have a blank line') if refused.any?(&:blank?)
  end

  # Enqueued after commit via enqueue_after_transaction_commit.
  def match_documents_later
    Disclosures::TopicMatchJob.perform_later
  end
end
