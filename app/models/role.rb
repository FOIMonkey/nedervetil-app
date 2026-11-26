# == Schema Information
#
# Table name: roles
#
#  id            :integer          not null, primary key
#  name          :string
#  resource_type :string
#  resource_id   :integer
#  created_at    :datetime         not null
#  updated_at    :datetime         not null
#

# Site-wide user role (admin only). Legacy resource_type/resource_id columns
# must stay blank; rows with them are ignored by `site_wide`.
class Role < ApplicationRecord
  has_and_belongs_to_many :users,
                          join_table: :users_roles,
                          inverse_of: :roles

  validates :resource_type, :resource_id, absence: true

  scope :site_wide, -> { where(resource_type: nil, resource_id: nil) }

  ROLES = %w[admin].freeze

  def self.allowed_roles
    ROLES
  end

  validates :name,
            inclusion: { in: -> (_name) { Role.allowed_roles } },
            uniqueness: { scope: %i[resource_type resource_id] }

  def self.admin_role
    site_wide.find_by(name: 'admin')
  end

  # Public: Returns an array of symbols of the names of the roles
  # which can be granted or revoked
  #
  # Returns an Array
  def self.grantable_roles
    allowed_roles.flat_map do |role|
      grants_and_revokes(role.to_sym)
    end.compact.uniq
  end

  # Public: Returns an array of symbols of the names of the roles
  # this role can grant and revoke
  #
  # role - the name of the role as a symbol
  #
  # Returns an Array
  def self.grants_and_revokes(role)
    grants_and_revokes = {
      admin: [:admin]
    }
    grants_and_revokes[role] || []
  end
end
