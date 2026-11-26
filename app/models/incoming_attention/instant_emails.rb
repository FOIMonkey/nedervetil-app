# == Schema Information
#
# Table name: incoming_attention_instant_emails
#
#  id         :bigint           not null, primary key
#  user_id    :bigint           not null
#  created_at :datetime         not null
#  updated_at :datetime         not null
#

module IncomingAttention
  # An account that chose an email per reply instead of the daily summary.
  # Read when core creates a notification (User#notification_frequency), so it
  # applies from then on.
  class InstantEmails < ApplicationRecord
    include AccountSetting

    self.table_name = 'incoming_attention_instant_emails'
    belongs_to :user
  end
end
