# == Schema Information
#
# Table name: announcement_dismissals
#
#  id              :integer          not null, primary key
#  announcement_id :integer          not null
#  user_id         :integer          not null
#  created_at      :datetime         not null
#  updated_at      :datetime         not null
#

# Records that a User has dismissed an Announcement so it is not shown again.
class AnnouncementDismissal < ApplicationRecord
  belongs_to :announcement,
             inverse_of: :dismissals
  belongs_to :user,
             inverse_of: :announcement_dismissals
end
