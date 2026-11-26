# A separate single-use email action tied to account and credential state.
class PendingEmailChange < ApplicationRecord
  include SingleUseToken

  belongs_to :user
  validates :new_email, format: { with: Devise.email_regexp }

  def self.issue(user, address)
    raw, digest = new_token
    user.with_lock do
      where(user: user, consumed_at: nil).update_all(consumed_at: Time.current)
      create!(user: user, old_email: user.email,
              new_email: address.strip.downcase,
              credential_state: user.credential_state,
              token_digest: digest,
              expires_at: 1.day.from_now)
    end
    raw
  end

  # Not once another account has the address: the link can never work then,
  # so it stops before a password or a code is asked for.
  def usable_for?(account)
    user_id == account.id && live? &&
      old_email == account.email &&
      credential_state == account.credential_state &&
      !User.where.not(id: account.id).find_user_by_email(new_email)
  end

  def complete(account, password:, otp:)
    account.with_lock do
      with_lock do
        unless usable_for?(account) && account.active? &&
               account.valid_password?(password)
          return false
        end
        if account.otp_required_for_login && !account.verify_second_factor!(otp)
          return false
        end

        account.update!(email: new_email)
        account.email_histories.record_change(old_email, new_email)
        use!
      end
    end
  end
end
