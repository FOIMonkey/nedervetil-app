# == Schema Information
#
# Table name: announcements
#
#  id         :integer          not null, primary key
#  visibility :string
#  user_id    :integer          not null
#  created_at :datetime         not null
#  updated_at :datetime         not null
#  title      :string
#  content    :text
#

# A translated announcement shown site-wide, in the inbox or to users with a
# specific role, with per-user dismissal tracking through AnnouncementDismissal.
class Announcement < ApplicationRecord
  SITE_WIDE = 'everyone'.freeze
  # Stored as 'pro' for compatibility with existing inbox announcements.
  INBOX = 'pro'.freeze

  belongs_to :user,
             inverse_of: :announcements
  has_many :dismissals,
           class_name: 'AnnouncementDismissal',
           inverse_of: :announcement,
           dependent: :destroy

  translates :title, :content
  include Translatable

  default_scope -> { order(created_at: :desc) }
  scope :visible_to, -> (visible_to) { where(visibility: visible_to) }

  scope :for_user, -> (user, *visibilities) {
    where(
      'announcements.id NOT IN (SELECT announcement_id FROM ' \
      'announcement_dismissals WHERE user_id = :user_id)',
      user_id: user
    ).
      where('announcements.created_at >= ?', user.created_at).
      visible_to(visibilities)
  }

  scope :for_user_with_roles, -> (user, *roles) {
    for_user(user, *roles).
      where(
        'announcements.visibility IN (' \
          'SELECT roles.name FROM roles ' \
          'INNER JOIN users_roles ON users_roles.role_id = roles.id ' \
          'WHERE users_roles.user_id = :user_id' \
        ')',
        user_id: user
      )
  }

  scope :site_wide_for_user, -> (user = nil, dismissed_announcements = nil) {
    relation = visible_to(SITE_WIDE)
    return relation unless user || dismissed_announcements

    if user
      last_dismissed = relation.joins(:dismissals).
        where(announcement_dismissals: { user_id: user })
    else
      last_dismissed = relation.where(id: dismissed_announcements)
    end

    created_at = last_dismissed.pick(:created_at)

    if created_at
      relation.
        where('announcements.created_at > :created_at', created_at: created_at)
    else
      relation
    end
  }

  validates :content,
            presence: true
  validates :visibility,
            presence: true,
            inclusion: { in: [SITE_WIDE, INBOX] + Role.allowed_roles }

  after_initialize :set_defaults

  private

  def set_defaults
    self.visibility ||= SITE_WIDE
  end
end
