# == Schema Information
#
# Table name: incoming_attention_opt_outs
#
#  id         :bigint           not null, primary key
#  user_id    :bigint           not null
#  created_at :datetime         not null
#  updated_at :datetime         not null
#

module IncomingAttention
  # Stops new replies to an opted-out owner's requests from being sent to the
  # AI service; prior or in-flight readings are left intact.
  class OptOut < ApplicationRecord
    include AccountSetting

    self.table_name = 'incoming_attention_opt_outs'
    belongs_to :user

    def self.opted_out?(user)
      on?(user)
    end

    def self.guard!(request)
      raise IncomingAttention::Input::Unavailable, 'opted_out' if
        opted_out?(request&.user)
    end
  end
end
