# Audit log of admin changes to a user's trusted flag or admin role.
class User::PermissionChange < ApplicationRecord
  WHAT = %w[trusted admin].freeze

  belongs_to :user, inverse_of: :permission_changes
  belongs_to :changed_by, class_name: 'User', optional: true

  validates :what, inclusion: { in: WHAT }
  validates :granted, inclusion: { in: [true, false] }

  def self.current(user)
    { 'trusted' => user[:trusted], 'admin' => user.is_admin? }
  end

  def self.record(user, before, by:)
    current(user).each do |what, granted|
      next if granted == before[what]

      user.permission_changes.create!(what: what, granted: granted,
                                      changed_by: by)
    end
  end
end
