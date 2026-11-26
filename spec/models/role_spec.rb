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

require 'spec_helper'

RSpec.describe Role do
  it 'validates the role name is in the allowed roles' do
    role = Role.new(name: 'test')
    role.valid?
    expect(role.errors[:name]).to eq(["is not included in the list"])
  end

  it 'validates the role name is unique' do
    role = Role.new(name: 'admin')
    role.valid?
    expect(role.errors[:name]).to eq(["has already been taken"])
  end

  it 'validates the role has no resource' do
    role = Role.new(name: 'admin', resource_type: 'InfoRequest',
                    resource_id: 1)
    role.valid?
    expect(role.errors[:resource_type]).to eq(["must be blank"])
    expect(role.errors[:resource_id]).to eq(["must be blank"])
  end

  describe '.admin_role' do
    it 'returns role with name admin' do
      expect(Role.admin_role.name).to eq 'admin'
    end
  end

  # One admin level (#93), whatever the flag says.
  describe '.grantable_roles' do
    it 'returns an array [:admin]' do
      expect(Role.grantable_roles).to match_array %i[admin]
    end

    it 'returns the same with the alaveteli_pro flag on',
       feature: :alaveteli_pro do
      expect(Role.grantable_roles).to match_array %i[admin]
    end
  end

  describe '.grants_and_revokes' do
    it 'returns an array [:admin] when passed :admin' do
      expect(Role.grants_and_revokes(:admin)).
        to eq([:admin])
    end

    it 'returns an empty array when passed a role that is gone' do
      expect(Role.grants_and_revokes(:pro_admin)).to eq([])
    end
  end
end
