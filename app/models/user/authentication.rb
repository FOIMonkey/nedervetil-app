# Devise-backed authentication, two-factor enforcement and session revocation
# for User. Legacy password/OTP columns are never used for authentication.
module User::Authentication
  extend ActiveSupport::Concern

  included do
    attr_accessor :draft_claim_for_confirmation

    devise :two_factor_authenticatable, :two_factor_backupable,
           :recoverable, :confirmable, :registerable, :validatable,
           :timeoutable,
           otp_number_of_backup_codes: 12, otp_backup_code_length: 16

    prepend Policy

    alias_attribute :otp_backup_codes, :devise_otp_backup_codes
    scope :without_two_factor, -> {
      where(otp_required_for_login: false).or(where(otp_secret: nil))
    }
    scope :with_totp, -> {
      where(otp_required_for_login: true).where.not(otp_secret: nil)
    }
    before_validation :initialize_authentication_version, on: :create
    before_save :rotate_authentication_version
    after_save :synchronize_confirmation_fact
  end

  # Prepended over Devise's included modules so site policy takes precedence.
  module Policy
    def active_for_authentication?
      super && !closed? && !credential_reset_required? &&
        (!(is_admin? || requires_two_factor_enrolment?) ||
          AlaveteliConfiguration.enable_two_factor_auth)
    end

    # Unenrolled admins must fail normal Warden strategies and use enrolment.
    def otp_required_for_login
      self[:otp_required_for_login] || is_admin?
    end

    def requires_two_factor_enrolment?
      otp_required_for_login && !totp?
    end

    def authenticatable_salt
      "#{super}:#{authentication_version}"
    end

    def credential_state
      Digest::SHA256.hexdigest("#{id}:#{email}:#{encrypted_password}:#{authentication_version}")
    end

    def revoke_authentication!
      update!(authentication_version: SecureRandom.uuid)
    end

    # Serialize consumption across requests, including independent Warden
    # strategies. A stale instance must reload before comparing/consuming.
    def validate_and_consume_otp!(code, options = {})
      with_lock { super(code, options) }
    end

    def invalidate_otp_backup_code!(code)
      return false if code.blank?

      with_lock { super(code) }
    end

    def verify_second_factor!(code)
      return false unless totp?

      validate_and_consume_otp!(code.to_s) ||
        invalidate_otp_backup_code!(code.to_s)
    end

    def totp?
      self[:otp_required_for_login] && otp_secret.present?
    end

    def otp_enabled?
      totp?
    end

    # Re-sends confirmation under a row lock so the link goes to the current
    # address and races against confirmation or closure send nothing. Runs
    # an optional block under the same lock before mailing.
    def send_confirmation_while_pending
      with_lock do
        next false if confirmed? || closed?

        yield if block_given?
        send_confirmation_instructions
        true
      end
    end

    private

    def initialize_authentication_version
      if authentication_version.blank?
        self.authentication_version = SecureRandom.uuid
      end
      # Factory/operator creation may explicitly carry the existing confirmation
      # fact; public registration never permits this attribute.
      self.confirmed_at ||= Time.current if email_confirmed?
    end

    def rotate_authentication_version
      credentials = %w[email encrypted_password otp_secret
                       otp_required_for_login closed_at]
      changed = credentials.any? { |key| will_save_change_to_attribute?(key) }
      if persisted? && changed
        self.authentication_version = SecureRandom.uuid
        unless will_save_change_to_encrypted_password?
          self.reset_password_token = nil
        end
        self.confirmation_token = nil if will_save_change_to_email?
      end
      if encrypted_password.present? && will_save_change_to_encrypted_password?
        self.credential_reset_required = false
      end
    end

    def synchronize_confirmation_fact
      return if email_confirmed? == confirmed?

      update_column(:email_confirmed, confirmed?)
    end
  end
end
