# An expiring password-proved challenge that grants no account access.
class AuthenticationEnrolment < ApplicationRecord
  include SingleUseToken

  belongs_to :user
  encrypts :secret

  def self.start(session, user)
    raw, digest = new_token
    create!(user: user, credential_state: user.credential_state,
            token_digest: digest,
            secret: User.generate_otp_secret, expires_at: 5.minutes.from_now)
    session[:authentication_enrolment] = raw
  end

  def self.pending(session)
    record = find_by_token(session[:authentication_enrolment])
    record if record&.usable?
  end

  def usable?
    live? &&
      user.credential_state == credential_state &&
      user.active_for_authentication? &&
      !user.totp? && AlaveteliConfiguration.enable_two_factor_auth
  end

  def complete(code)
    user.with_lock do
      with_lock do
        return unless usable?

        timestep = ROTP::TOTP.new(secret).verify(code.to_s, drift_behind: 15,
                                                            drift_ahead: 15)
        return unless timestep

        user.otp_secret = secret
        user.otp_required_for_login = true
        user.consumed_timestep = timestep / 30
        codes = user.generate_otp_backup_codes!
        user.otp_enabled_at = Time.current
        user.otp_backup_codes_generated_at = Time.current
        user.save!
        use!
        codes
      end
    end
  end
end
