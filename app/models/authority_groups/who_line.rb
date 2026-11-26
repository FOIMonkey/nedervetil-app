# == Schema Information
#
# Table name: authority_who_lines
#
#  id             :bigint           not null, primary key
#  public_body_id :bigint           not null
#  line           :string           not null
#  created_at     :datetime         not null
#  updated_at     :datetime         not null
#

module AuthorityGroups
  # An admin's words for what one authority does, in place of the line Who
  # does what builds for it from the topic files (Topics::Holds.brief).
  class WhoLine < ApplicationRecord
    self.table_name = 'authority_who_lines'
    MAX = 200

    belongs_to :public_body

    validates :line, presence: true, length: { maximum: MAX }

    def self.save_for(body, line)
      line = line.to_s.squish
      return where(public_body: body).delete_all if line.empty?

      find_or_initialize_by(public_body: body).update(line: line)
    end
  end
end
