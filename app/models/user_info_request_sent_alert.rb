# == Schema Information
#
# Table name: user_info_request_sent_alerts
#
#  id                    :integer          not null, primary key
#  user_id               :integer          not null
#  info_request_id       :integer          not null
#  alert_type            :string           not null
#  info_request_event_id :integer
#  created_at            :datetime
#  updated_at            :datetime
#

# Copyright (c) 2008 UK Citizens Online Democracy. All rights reserved.
# Email: hello@mysociety.org; WWW: http://www.mysociety.org/

# Records an alert sent to a User about an InfoRequest and optional
# InfoRequestEvent. Keeps retired alert types in ALERT_TYPES valid so stored
# rows continue to load and validate.
class UserInfoRequestSentAlert < ApplicationRecord
  ALERT_TYPES = [
    # retired: the reminder emails are gone (doc/FORK.md); kept so old rows
    # stay valid
    'overdue_1', # the request became overdue
    'very_overdue_1', # the request became very overdue
    'new_response_reminder_1', # classify the recent response
    'new_response_reminder_2', # repeat of the classify reminder
    'new_response_reminder_3', # repeat of the classify reminder
    'not_clarified_1', # explain part of the request
    'comment_1', # retired: comments are gone (doc/FORK.md)
    'embargo_expiring_1', # retired: embargoes are gone (doc/FORK.md)
    'embargo_expired_1' # retired: embargoes are gone (doc/FORK.md)
  ].freeze

  belongs_to :user,
             inverse_of: :user_info_request_sent_alerts
  belongs_to :info_request,
             inverse_of: :user_info_request_sent_alerts
  belongs_to :info_request_event,
             inverse_of: :user_info_request_sent_alerts,
             optional: true

  validates_inclusion_of :alert_type, in: ALERT_TYPES

  scope :recent, -> { where(created_at: 1.year.ago.to_date..Float::INFINITY) }
end
