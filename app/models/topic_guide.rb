# == Schema Information
#
# Table name: topic_guides
#
#  id            :bigint           not null, primary key
#  dataset_id    :string
#  topic_slug    :string
#  question_slug :string
#  published     :boolean          default(FALSE), not null
#  created_at    :datetime         not null
#  updated_at    :datetime         not null
#

# Admin-written rich-text guide (no attachments) attached to a dataset,
# a topic question, or both. Distinct from Topics::Guide.
class TopicGuide < ApplicationRecord
  translates :title
  translates :body, touch: true
  include Translatable
  include TopicChange::Checked
  delegate :body, :body=, :body?, to: :translation
  after_save { body.save if body.changed? }

  validates :body, presence: true
  validate :applies_to_something
  validates :dataset_id, uniqueness: { scope: %i[topic_slug question_slug],
                                       message: 'already has a guide' }

  normalizes :dataset_id, :topic_slug, :question_slug,
             with: ->(value) { value.presence }

  scope :published, -> { where(published: true) }

  # Returns [source guide, question guide], preferring a paired question guide.
  def self.for(topic, entry, drafts: false)
    source = entry.dataset&.id
    base = drafts ? all : published
    found = base.where(topic_slug: nil, question_slug: nil, dataset_id: source).
            or(base.where(topic_slug: topic.slug, question_slug: entry.slug,
                          dataset_id: [nil, source].uniq)).
            includes(:translations).to_a
    own = found.select(&:question_slug)
    [found.find { |guide| source && guide.question_slug.nil? },
     own.find { |guide| source && guide.dataset_id == source } ||
       own.find { |guide| guide.dataset_id.nil? }].compact
  end

  def source
    dataset_id && Topics::Dataset.find(dataset_id)
  end

  def topic
    topic_slug && Topics::Topic.find(topic_slug)
  end

  def question
    topic&.question(question_slug)
  end

  def question_key
    "#{topic_slug}/#{question_slug}" if topic_slug
  end

  def question_key=(value)
    self.topic_slug, self.question_slug = value.to_s.split('/', 2)
  end

  def applies_to
    [question&.text, source&.title].compact.join(', from ')
  end

  private

  def applies_to_something
    if topic_slug.nil? != question_slug.nil?
      errors.add(:base, 'Pick a whole question: its topic and the question')
    elsif dataset_id.nil? && topic_slug.nil?
      errors.add(:base, 'Pick a source, a question, or both')
    end
    applies_to_real_things
  end

  def applies_to_real_things
    if dataset_id && !source
      errors.add(:dataset_id, 'isn’t a source the topics use')
    end
    if topic_slug && !question
      errors.add(:question_key, 'isn’t a question the topics have')
    end
    return unless source && question && !question_sources.include?(dataset_id)

    errors.add(:dataset_id, 'doesn’t answer that question in any nation')
  end

  def question_sources
    topic.questions.select { |each| each.slug == question_slug }.
      flat_map do |each|
        each.dataset.is_a?(Hash) ? each.dataset.values : Array(each.dataset)
      end
  end

  class Translation # :nodoc:
    extend ActionText::WithoutAttachments
    has_rich_text_without_attachments :body
  end
end
