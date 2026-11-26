# == Schema Information
#
# Table name: request_classifications
#
#  id                    :integer          not null, primary key
#  user_id               :integer
#  info_request_event_id :integer
#  created_at            :datetime         not null
#  updated_at            :datetime         not null
#

# Links a User to a status-update InfoRequestEvent when a request is
# classified, updating the user's classification counter.
class RequestClassification < ApplicationRecord
  belongs_to :user,
             inverse_of: :request_classifications,
             counter_cache: true
  belongs_to :info_request_event,
             inverse_of: :request_classification
end
