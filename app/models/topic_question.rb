# Question row for a TopicPage. `slug` is immutable (referenced by URLs and
# TopicGuide) and may be shared only across non-overlapping nations.
class TopicQuestion < ApplicationRecord
  include TopicPage::Row

  validates :text, presence: true
  validates :slug, presence: true,
                   format: { with: Topics::Topic::SLUG, allow_blank: true },
                   exclusion: { in: Topics::Topic::RESERVED }
  validate :slug_kept, on: :update
  validate :slug_free_in_its_nations
  validates :dataset, :holder, topic_nations: { map: true }
  validates :ask, topic_link: true
  validates :published, topic_url: true
  validate :keywords_written

  private

  def slug_kept
    errors.add(:slug, 'can’t change once the question exists') if
      slug_changed?
  end

  def slug_free_in_its_nations
    return unless topic_page && slug

    mine = all_nations(self)
    taken = topic_page.questions.where(slug: slug).where.not(id: id).
            any? { |other| all_nations(other).intersect?(mine) }
    errors.add(:slug, 'is another question’s in the same nation') if taken
  end

  def all_nations(question)
    question.nations.presence || Topics::Topic::NATIONS.keys
  end

  def keywords_written
    return unless keywords.any?(&:blank?)

    errors.add(:keywords, 'can’t have a blank phrase')
  end
end
