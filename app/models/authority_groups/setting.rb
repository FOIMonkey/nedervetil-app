# == Schema Information
#
# Table name: authority_group_settings
#
#  id          :bigint           not null, primary key
#  category_id :bigint           not null
#  hidden_at   :datetime
#  created_at  :datetime         not null
#  updated_at  :datetime         not null
#

module AuthorityGroups
  # A group's own settings: whether it is hidden from visitors.
  class Setting < ApplicationRecord
    self.table_name = 'authority_group_settings'

    belongs_to :category

    def self.hide!(category)
      find_or_create_by!(category: category).update!(hidden_at: Time.current)
    end

    def self.show!(category)
      where(category: category).
        update_all(hidden_at: nil, updated_at: Time.current)
    end
  end
end
