# Record holder row for a TopicPage. Once set, `key` is immutable because
# `holds_not:` authority tags and TopicQuestion#holder reference it.
class TopicHolder < ApplicationRecord
  include TopicPage::Row

  validates :what, :who, presence: true
  validates :to, topic_link: true
  validate :groups_labelled_and_tagged
  validate :key_kept, on: :update

  after_update :renamed_in_questions, if: :saved_change_to_who?

  private

  def renamed_in_questions
    old = who_before_last_save
    holders = TopicHolder.where(topic_page_id: topic_page_id).
              order(:position, :id).to_a
    topic_page.questions.each do |question|
      holder = question.holder.to_h do |nation, name|
        [nation, name == old && found?(holders, nation, old) ? who : name]
      end
      question.update!(holder: holder) unless holder == question.holder
    end
  end

  # Mirrors Topics::Guide#holder_for: true if this was first match in nation.
  def found?(holders, nation, old)
    holders.find do |each|
      names = each.id == id ? [key, old] : [each.key, each.who]
      (each.nations.empty? || each.nations.include?(nation)) &&
        names.include?(old)
    end&.id == id
  end

  def key_kept
    return unless key_changed? && key_was.present?

    errors.add(:key, 'can’t change once given')
  end

  def groups_labelled_and_tagged
    return if groups.is_a?(Array) && groups.all? { |group| group?(group) }

    errors.add(:groups, 'must each have a label and a tag')
  end

  def group?(group)
    group.is_a?(Hash) && group.keys.sort == %w[label tag] &&
      group.values.all? { |each| each.is_a?(String) && each.present? }
  end
end
