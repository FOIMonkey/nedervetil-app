# == Schema Information
#
# Table name: request_limit_sends
#
#  id              :bigint           not null, primary key
#  user_id         :bigint           not null
#  kind            :string           not null
#  info_request_id :bigint
#  created_at      :datetime         not null
#

module RequestLimits
  # No text and no addresses. info_request_id has no foreign key, so the row
  # outlives a deleted request.
  class Send < ApplicationRecord
    self.table_name = 'request_limit_sends'
    KINDS = %w[request followup batch].freeze

    validates :kind, inclusion: { in: KINDS }
  end
end
