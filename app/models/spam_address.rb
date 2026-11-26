# == Schema Information
#
# Table name: spam_addresses
#
#  id         :integer          not null, primary key
#  email      :string           not null
#  created_at :datetime         not null
#  updated_at :datetime         not null
#

# Blocklisted email address checked by RequestMailbox before routing incoming
# mail, stored normalised and lower-cased.
class SpamAddress < ApplicationRecord
  validates_presence_of :email,
                        message: 'Enter the email address to mark as spam'

  validates_uniqueness_of :email,
                          message: 'This address is already marked as spam'

  normalizes :email, with: Whitespace::TRIM_TO_NIL

  before_save :downcase_email

  def self.spam?(email_address)
    exists?(email: Array(email_address).compact.map(&:downcase))
  end

  private

  def downcase_email
    email.downcase!
  end
end
